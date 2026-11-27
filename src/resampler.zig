//! Deterministic sample-rate conversion.
//!
//! Output frame `m` is evaluated at the exact rational input position
//! `m * source_rate / target_rate`. The position is derived from `m` alone, so
//! the produced samples do not depend on how the input is split into chunks and
//! no rounding drift accumulates over a long stream.
//!
//! The kernel is a 97-tap Blackman-Harris windowed sinc. Its cutoff is
//! `0.5 * 0.90625` cycles per input sample when upsampling and
//! `0.5 * 0.90625 * target/source` when downsampling, so the kernel narrows to
//! the target Nyquist limit. Each phase is normalised to unit DC gain. Equal
//! source and target rates bypass the filter entirely, which keeps decoded FLAC
//! output bit-exact whenever no rate change is requested.
//!
//! Samples outside the available input are treated as zero: before the first
//! sample and, during the end-of-stream drain, after the last one. There is no
//! rate-dependent latency compensation because the first output frame is
//! aligned with input time zero.
const std = @import("std");

pub const tap_count: usize = 97;
pub const half_taps: i64 = @as(i64, tap_count / 2);
pub const max_cached_phases: u32 = 4096;
/// Passband edge as a fraction of the target Nyquist frequency.
pub const passband: f64 = 0.90625;
/// Largest supported conversion ratio in either direction. Audio rates span
/// roughly 8 kHz to 384 kHz, so 384000/44100 = 1280/147 is the widest realistic
/// pair; this admits it while rejecting degenerate ratios whose cutoff would
/// collapse toward zero.
pub const max_ratio: u64 = 8192;

pub const Resampler = struct {
    source_rate: u32,
    target_rate: u32,
    channels: u8,
    /// Reduced numerator of the step: source_rate / gcd.
    step: u64,
    /// Reduced denominator of the step: target_rate / gcd.
    denominator: u64,
    /// Cutoff in cycles per input sample, always below 0.5.
    cutoff: f64,
    bypass: bool,
    finished: bool = false,

    /// Allocation backing the retained input window.
    history: []f64 = &.{},
    /// Frames actually present in `history`, interleaved by channel.
    history_len: usize = 0,
    /// Absolute input frame index of `history[0]`.
    history_start: u64 = 0,
    /// Absolute number of input frames supplied so far.
    input_frames: u64 = 0,
    /// Absolute number of output frames produced so far.
    output_frames: u64 = 0,
    /// Phase-major coefficient table, or null when phases are evaluated directly.
    table: ?[]f64 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        source_rate: u32,
        target_rate: u32,
        channels: u8,
    ) !Resampler {
        if (source_rate == 0 or target_rate == 0 or channels == 0 or channels > 8) {
            return error.InvalidAudioFormat;
        }
        // Bounds both the rational state and any single block the caller may pass.
        if (source_rate > max_sample_rate or target_rate > max_sample_rate) {
            return error.UnsupportedSampleRate;
        }
        const divisor = std.math.gcd(source_rate, target_rate);
        const step: u64 = source_rate / divisor;
        const denominator: u64 = target_rate / divisor;
        if (step > max_ratio or denominator > max_ratio) return error.UnsupportedRatio;
        const cutoff = if (target_rate < source_rate)
            0.5 * passband * @as(f64, @floatFromInt(target_rate)) / @as(f64, @floatFromInt(source_rate))
        else
            0.5 * passband;
        var self = Resampler{
            .source_rate = source_rate,
            .target_rate = target_rate,
            .channels = channels,
            .step = step,
            .denominator = denominator,
            .cutoff = cutoff,
            .bypass = source_rate == target_rate,
        };
        errdefer self.deinit(allocator);
        if (!self.bypass and denominator <= max_cached_phases) {
            const count = std.math.mul(usize, @intCast(denominator), tap_count) catch
                return error.AudioDurationOverflow;
            const table = try allocator.alloc(f64, count);
            for (0..@intCast(denominator)) |index| {
                try fillWeights(
                    table[index * tap_count ..][0..tap_count],
                    @intCast(index),
                    denominator,
                    cutoff,
                );
            }
            self.table = table;
        }
        return self;
    }

    pub fn deinit(self: *Resampler, allocator: std.mem.Allocator) void {
        if (self.history.len != 0) allocator.free(self.history);
        if (self.table) |table| allocator.free(table);
        self.* = undefined;
    }

    /// Frame count of a complete stream of `input_frames` frames.
    pub fn frameCount(input_frames: u64, source_rate: u32, target_rate: u32) !u64 {
        if (source_rate == 0 or target_rate == 0) return error.InvalidAudioFormat;
        if (source_rate > max_sample_rate or target_rate > max_sample_rate) {
            return error.UnsupportedSampleRate;
        }
        const product = try std.math.mul(u64, input_frames, target_rate);
        const rounded = try std.math.add(u64, product, source_rate - 1);
        return rounded / source_rate;
    }

    /// Output frames the current stream will yield once fully drained.
    pub fn totalOutputFrames(self: *const Resampler) !u64 {
        return frameCount(self.input_frames, self.source_rate, self.target_rate);
    }

    /// Append interleaved input and return every output frame that is now
    /// determined. Output is identical for any chunking of the same input.
    /// After a drain (`end_of_stream = true`) the only valid call is another
    /// drain with no input, which returns an empty slice.
    pub fn process(
        self: *Resampler,
        allocator: std.mem.Allocator,
        input: []const f64,
        end_of_stream: bool,
    ) ![]f64 {
        const channels: usize = self.channels;
        if (input.len % channels != 0) return error.InvalidAudioBuffer;
        for (input) |sample| {
            if (!std.math.isFinite(sample)) return error.InvalidAudioSample;
        }
        if (self.finished and (input.len != 0 or !end_of_stream)) {
            return error.StreamAlreadyFinished;
        }

        const added_frames: u64 = input.len / channels;
        try self.appendInput(allocator, input, added_frames);
        if (end_of_stream) self.finished = true;

        if (self.bypass) {
            const copied = try allocator.dupe(f64, input);
            self.output_frames = std.math.add(u64, self.output_frames, added_frames) catch {
                allocator.free(copied);
                return error.AudioDurationOverflow;
            };
            return copied;
        }

        const total = try self.totalOutputFrames();
        var output: std.ArrayList(f64) = .empty;
        errdefer output.deinit(allocator);
        var weight_buffer: [tap_count]f64 = undefined;
        while (self.canEmit(total)) {
            const weights = try self.weightsFor(&weight_buffer);
            try self.filterFrame(allocator, &output, weights);
            self.output_frames = std.math.add(u64, self.output_frames, 1) catch
                return error.AudioDurationOverflow;
        }
        try self.discardUnused();
        return output.toOwnedSlice(allocator);
    }

    fn appendInput(
        self: *Resampler,
        allocator: std.mem.Allocator,
        input: []const f64,
        added_frames: u64,
    ) !void {
        const channels: usize = self.channels;
        if (added_frames == 0) return;
        const needed_frames = std.math.add(usize, self.history_len, @intCast(added_frames)) catch
            return error.AudioDurationOverflow;
        const needed = std.math.mul(usize, needed_frames, channels) catch
            return error.AudioDurationOverflow;
        if (needed > self.history.len) {
            var capacity = if (self.history.len == 0) needed else self.history.len;
            while (capacity < needed) {
                capacity = std.math.mul(usize, capacity, 2) catch needed;
                if (capacity < needed) return error.AudioDurationOverflow;
            }
            self.history = if (self.history.len == 0)
                try allocator.alloc(f64, capacity)
            else
                try allocator.realloc(self.history, capacity);
        }
        const offset = self.history_len * channels;
        @memcpy(self.history[offset..][0..input.len], input);
        self.history_len = needed_frames;
        self.input_frames = std.math.add(u64, self.input_frames, added_frames) catch
            return error.AudioDurationOverflow;
    }

    fn canEmit(self: *const Resampler, total: u64) bool {
        if (self.output_frames >= total) return false;
        const center = self.centerFrame(self.output_frames) orelse return false;
        if (!self.finished) {
            // Every tap must observe real input: the last needed index is
            // center + half_taps, which must be below input_frames.
            const right = std.math.add(u64, center, @intCast(half_taps)) catch return false;
            return right < self.input_frames;
        }
        return center < self.input_frames;
    }

    fn centerFrame(self: *const Resampler, output_index: u64) ?u64 {
        const numerator = std.math.mul(u64, output_index, self.step) catch return null;
        return numerator / self.denominator;
    }

    fn phaseOf(self: *const Resampler, output_index: u64) u32 {
        const numerator = std.math.mul(u64, output_index, self.step) catch unreachable;
        return @intCast(numerator % self.denominator);
    }

    fn weightsFor(self: *const Resampler, scratch: *[tap_count]f64) ![]const f64 {
        const phase = self.phaseOf(self.output_frames);
        if (self.table) |table| {
            return table[@as(usize, phase) * tap_count ..][0..tap_count];
        }
        try fillWeights(scratch, phase, self.denominator, self.cutoff);
        return scratch[0..tap_count];
    }

    fn filterFrame(
        self: *const Resampler,
        allocator: std.mem.Allocator,
        output: *std.ArrayList(f64),
        weights: []const f64,
    ) !void {
        const channels: usize = self.channels;
        const center = self.centerFrame(self.output_frames) orelse return error.AudioDurationOverflow;
        var channel: usize = 0;
        while (channel < channels) : (channel += 1) {
            var sum: f64 = 0.0;
            for (weights, 0..) |weight, tap| {
                const offset = @as(i64, @intCast(tap)) - half_taps;
                const sample = self.sampleAt(center, offset, channel);
                sum += sample * weight;
            }
            try output.append(allocator, sum);
        }
    }

    fn sampleAt(self: *const Resampler, center: u64, offset: i64, channel: usize) f64 {
        const index = @as(i64, @intCast(center)) + offset;
        if (index < 0) return 0.0;
        const absolute: u64 = @intCast(index);
        if (absolute >= self.input_frames) return 0.0;
        if (absolute < self.history_start) return 0.0;
        const relative = absolute - self.history_start;
        if (relative >= self.history_len) return 0.0;
        return self.history[@as(usize, @intCast(relative)) * self.channels + channel];
    }

    /// Release input frames that can no longer contribute to a later frame.
    fn discardUnused(self: *Resampler) !void {
        const channels: usize = self.channels;
        const next_center = self.centerFrame(self.output_frames) orelse return;
        const keep_from = next_center -| @as(u64, @intCast(half_taps));
        if (keep_from <= self.history_start) return;
        const drop = keep_from - self.history_start;
        const drop_samples = std.math.mul(usize, @intCast(drop), channels) catch
            return error.AudioDurationOverflow;
        const used = self.history_len * channels;
        std.mem.copyForwards(f64, self.history[0 .. used - drop_samples], self.history[drop_samples..used]);
        self.history_len -= @intCast(drop);
        self.history_start = keep_from;
    }
};

const max_sample_rate: u32 = 1_000_000;

fn sinc(x: f64) f64 {
    if (@abs(x) < 1e-12) return 1.0;
    const angle = std.math.pi * x;
    return @sin(angle) / angle;
}

fn kernel(distance: f64, cutoff: f64) f64 {
    const limit = @as(f64, @floatFromInt(half_taps));
    if (@abs(distance) >= limit) return 0.0;
    const x = distance / limit;
    const window = 0.35875 +
        0.48829 * @cos(std.math.pi * x) +
        0.14128 * @cos(2.0 * std.math.pi * x) +
        0.01168 * @cos(3.0 * std.math.pi * x);
    const t = 2.0 * cutoff * distance;
    return 2.0 * cutoff * sinc(t) * window;
}

fn fillWeights(weights: []f64, phase: u32, denominator: u64, cutoff: f64) !void {
    std.debug.assert(weights.len == tap_count);
    const fraction = @as(f64, @floatFromInt(phase)) / @as(f64, @floatFromInt(denominator));
    var sum: f64 = 0.0;
    for (weights, 0..) |*weight, tap| {
        const position = @as(f64, @floatFromInt(tap)) - @as(f64, @floatFromInt(half_taps));
        weight.* = kernel(fraction - position, cutoff);
        sum += weight.*;
    }
    // Normalising each phase removes periodic gain ripple from the truncated
    // kernel; the passband margin keeps that correction out of the audio band.
    // A sum near zero means the kernel has gone degenerate rather than merely
    // narrow, so it is reported instead of producing amplified noise.
    if (!std.math.isFinite(sum) or @abs(sum) < 1e-6) return error.UnsupportedRatio;
    for (weights) |*weight| weight.* /= sum;
}

test "identity rates bypass the filter exactly" {
    const allocator = std.testing.allocator;
    var resampler = try Resampler.init(allocator, 44100, 44100, 2);
    defer resampler.deinit(allocator);
    const input = [_]f64{ 0.25, -0.5, 1.0, -1.0 };
    const output = try resampler.process(allocator, &input, true);
    defer allocator.free(output);
    try std.testing.expectEqualSlices(f64, &input, output);
}

test "frame counts round up and handle empty input" {
    try std.testing.expectEqual(@as(u64, 0), try Resampler.frameCount(0, 44100, 48000));
    try std.testing.expectEqual(@as(u64, 1), try Resampler.frameCount(1, 96000, 48000));
    try std.testing.expectEqual(@as(u64, 2), try Resampler.frameCount(1, 48000, 96000));
    try std.testing.expectEqual(@as(u64, 48000), try Resampler.frameCount(44100, 44100, 48000));
}

test "weights have unit DC gain for every cached phase" {
    const allocator = std.testing.allocator;
    var resampler = try Resampler.init(allocator, 44100, 48000, 1);
    defer resampler.deinit(allocator);
    const table = resampler.table.?;
    var phase: usize = 0;
    while (phase < @as(usize, @intCast(resampler.denominator))) : (phase += 1) {
        var sum: f64 = 0.0;
        for (table[phase * tap_count ..][0..tap_count]) |weight| sum += weight;
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), sum, 1e-12);
    }
}
