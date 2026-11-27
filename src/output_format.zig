//! Deterministic conversion from decoded FLAC samples to a playback format.
//!
//! The playback service accepts signed 16-bit stereo PCM at a fixed rate, so
//! every track is mapped onto one target `Format`. Conversion normalises the
//! decoded integers of the source bit depth into `[-1, 1)`, resamples when the
//! rates differ, duplicates mono into both channels, and quantises to signed
//! 16-bit little-endian. Equal rates and 16-bit sources therefore take an
//! exact integer path and stay bit-identical to the decoder output.
//!
//! Quantisation rounds to nearest with no dithering: identical input always
//! produces identical bytes, which is what the differential tests and the
//! crossfade overlap rely on. Sources wider than the target bit depth are
//! rounded, so playback is not claimed to be bit-perfect; offline rendering
//! keeps the source layout and is unaffected by this module.
const std = @import("std");
const resampler = @import("resampler.zig");

pub const Format = struct {
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,

    pub fn frames(self: Format, sample_count: usize) usize {
        return sample_count / self.channels;
    }
};

/// The format the local audio service is opened with.
pub const playback_format = Format{ .sample_rate = 44100, .channels = 2, .bits_per_sample = 16 };

pub const max_source_channels: u8 = 2;

pub fn validateSource(source: Format) !void {
    if (source.sample_rate == 0 or source.bits_per_sample == 0 or source.bits_per_sample > 32) {
        return error.InvalidAudioFormat;
    }
    if (source.channels == 0) return error.InvalidAudioFormat;
    if (source.channels > max_source_channels) return error.UnsupportedPlaybackChannels;
}

pub fn validateTarget(target: Format) !void {
    if (target.sample_rate == 0 or target.channels == 0) return error.InvalidAudioFormat;
    if (target.channels != 1 and target.channels != 2) return error.UnsupportedPlaybackChannels;
    if (target.bits_per_sample != 16) return error.UnsupportedOutputFormat;
}

/// Total output frames for a complete source of `source_frames` frames.
pub fn outputFrames(source_frames: u64, source: Format, target: Format) !u64 {
    return resampler.Resampler.frameCount(source_frames, source.sample_rate, target.sample_rate);
}

/// Streaming converter: append decoded chunks, receive interleaved s16le bytes
/// in the target format. Output never depends on how the source is chunked.
pub const Converter = struct {
    source: Format,
    target: Format,
    resampler: resampler.Resampler,
    /// Interleaved target-channel samples awaiting quantisation.
    pending: std.ArrayList(f64) = .empty,

    pub fn init(allocator: std.mem.Allocator, source: Format, target: Format) !Converter {
        try validateSource(source);
        try validateTarget(target);
        return .{
            .source = source,
            .target = target,
            .resampler = try resampler.Resampler.init(
                allocator,
                source.sample_rate,
                target.sample_rate,
                source.channels,
            ),
        };
    }

    pub fn deinit(self: *Converter, allocator: std.mem.Allocator) void {
        self.resampler.deinit(allocator);
        self.pending.deinit(allocator);
        self.* = undefined;
    }

    /// Convert one chunk of interleaved source samples.
    pub fn process(
        self: *Converter,
        allocator: std.mem.Allocator,
        samples: []const i64,
        end_of_stream: bool,
    ) ![]u8 {
        for (samples) |sample| {
            const bound = sourceBound(self.source.bits_per_sample);
            if (sample < -bound or sample >= bound) return error.InvalidAudioSample;
        }
        const normalised = try allocator.alloc(f64, samples.len);
        defer allocator.free(normalised);
        for (samples, 0..) |sample, index| {
            normalised[index] = normalise(sample, self.source.bits_per_sample);
        }
        const converted = try self.resampler.process(allocator, normalised, end_of_stream);
        defer allocator.free(converted);
        return self.emit(allocator, converted);
    }

    /// Drain the filter tail. Valid once, after the last chunk.
    pub fn finish(self: *Converter, allocator: std.mem.Allocator) ![]u8 {
        return self.process(allocator, &.{}, true);
    }

    fn emit(self: *Converter, allocator: std.mem.Allocator, frames: []const f64) ![]u8 {
        const target_channels = self.target.channels;
        const frame_count = frames.len / self.source.channels;
        const bytes = try allocator.alloc(u8, frame_count * target_channels * 2);
        errdefer allocator.free(bytes);
        var frame: usize = 0;
        while (frame < frame_count) : (frame += 1) {
            const left = quantise(frames[frame * self.source.channels]);
            const right = if (self.source.channels == 1)
                left
            else
                quantise(frames[frame * self.source.channels + 1]);
            if (target_channels == 1) {
                // Downmix is only used for mono targets: average keeps the
                // level of a correlated stereo pair and cannot clip.
                writeSample(bytes, frame, roundHalf(0.5 * (@as(f64, @floatFromInt(left)) +
                    @as(f64, @floatFromInt(right)))));
            } else {
                writeSample(bytes, frame * 2, left);
                writeSample(bytes, frame * 2 + 1, right);
            }
        }
        return bytes;
    }
};

/// Convert a complete decoded buffer in one call.
pub fn convert(
    allocator: std.mem.Allocator,
    samples: []const i64,
    source: Format,
    target: Format,
) ![]u8 {
    try validateSource(source);
    if (samples.len % source.channels != 0) return error.InvalidAudioBuffer;
    var converter = try Converter.init(allocator, source, target);
    defer converter.deinit(allocator);
    const converted = try converter.process(allocator, samples, false);
    errdefer allocator.free(converted);
    const tail = try converter.finish(allocator);
    defer allocator.free(tail);
    if (tail.len == 0) return converted;
    const joined = try allocator.alloc(u8, converted.len + tail.len);
    @memcpy(joined[0..converted.len], converted);
    @memcpy(joined[converted.len..], tail);
    allocator.free(converted);
    return joined;
}

/// Largest magnitude representable in `bits` two's-complement samples.
pub fn sourceBound(bits: u8) i64 {
    return @as(i64, 1) << @intCast(bits - 1);
}

fn normalise(sample: i64, bits: u8) f64 {
    const bound = sourceBound(bits);
    const limit_max: f64 = @floatFromInt(bound - 1);
    const limit_min: f64 = @floatFromInt(-bound);
    const value: f64 = @floatFromInt(sample);
    const clamped = @max(limit_min, @min(limit_max, value));
    return if (clamped < 0) clamped / -limit_min else clamped / limit_max;
}

fn quantise(normalised: f64) i16 {
    const clamped = @max(-1.0, @min(1.0, normalised));
    const scaled = if (clamped < 0) clamped * 32768.0 else clamped * 32767.0;
    return @intFromFloat(@round(@max(-32768.0, @min(32767.0, scaled))));
}

fn roundHalf(value: f64) i16 {
    return @intFromFloat(@round(@max(-32768.0, @min(32767.0, value))));
}

fn writeSample(bytes: []u8, index: usize, value: i16) void {
    const bits: u16 = @bitCast(value);
    bytes[index * 2] = @truncate(bits);
    bytes[index * 2 + 1] = @truncate(bits >> 8);
}

test "identity 16-bit stereo conversion is bit-exact" {
    const allocator = std.testing.allocator;
    const samples = [_]i64{ -32768, 32767, 0, -1, 1, 16384 };
    const source = Format{ .sample_rate = 44100, .channels = 2, .bits_per_sample = 16 };
    const bytes = try convert(allocator, &samples, source, source);
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 12), bytes.len);
    const expected = [_]i16{ -32768, 32767, 0, -1, 1, 16384 };
    for (expected, 0..) |value, index| {
        const actual: i16 = @bitCast(@as(u16, bytes[index * 2]) | (@as(u16, bytes[index * 2 + 1]) << 8));
        try std.testing.expectEqual(value, actual);
    }
}

test "mono duplicates into both channels after resampling" {
    const allocator = std.testing.allocator;
    const samples = [_]i64{ -32768, 0, 32767 };
    const source = Format{ .sample_rate = 44100, .channels = 1, .bits_per_sample = 16 };
    const bytes = try convert(allocator, &samples, source, playback_format);
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 12), bytes.len);
    try std.testing.expectEqualSlices(u8, bytes[0..2], bytes[2..4]);
    try std.testing.expectEqualSlices(u8, bytes[8..10], bytes[10..12]);
}

test "multichannel sources are rejected before conversion" {
    const allocator = std.testing.allocator;
    const samples = [_]i64{ 0, 0, 0, 0, 0, 0 };
    const source = Format{ .sample_rate = 44100, .channels = 6, .bits_per_sample = 16 };
    try std.testing.expectError(
        error.UnsupportedPlaybackChannels,
        convert(allocator, &samples, source, playback_format),
    );
}

test "unknown bit depths and empty formats are rejected" {
    const allocator = std.testing.allocator;
    const samples = [_]i64{0};
    try std.testing.expectError(
        error.InvalidAudioFormat,
        convert(allocator, &samples, .{ .sample_rate = 44100, .channels = 1, .bits_per_sample = 0 }, playback_format),
    );
    try std.testing.expectError(
        error.InvalidAudioFormat,
        convert(allocator, &samples, .{ .sample_rate = 44100, .channels = 1, .bits_per_sample = 33 }, playback_format),
    );
}

test "chunked conversion matches one-shot conversion" {
    const allocator = std.testing.allocator;
    const frames: usize = 1000;
    const source_samples = try allocator.alloc(i64, frames);
    defer allocator.free(source_samples);
    for (source_samples, 0..) |*sample, index| {
        sample.* = @intCast(@mod(@as(i64, @intCast(index)) * 37, 65536) - 32768);
    }
    const source = Format{ .sample_rate = 48000, .channels = 1, .bits_per_sample = 16 };
    const whole = try convert(allocator, source_samples, source, playback_format);
    defer allocator.free(whole);

    var converter = try Converter.init(allocator, source, playback_format);
    defer converter.deinit(allocator);
    var streamed: std.ArrayList(u8) = .empty;
    defer streamed.deinit(allocator);
    var offset: usize = 0;
    while (offset < source_samples.len) {
        const count = @min(@as(usize, 7), source_samples.len - offset);
        const chunk = try converter.process(allocator, source_samples[offset..][0..count], false);
        defer allocator.free(chunk);
        try streamed.appendSlice(allocator, chunk);
        offset += count;
    }
    const tail = try converter.finish(allocator);
    defer allocator.free(tail);
    try streamed.appendSlice(allocator, tail);
    try std.testing.expectEqualSlices(u8, whole, streamed.items);
}

test "output frame count follows the rational ratio" {
    // 48000 input frames at 48 kHz become 44100 frames at 44.1 kHz.
    try std.testing.expectEqual(
        @as(u64, 44100),
        try outputFrames(48000, .{ .sample_rate = 48000, .channels = 2, .bits_per_sample = 16 }, playback_format),
    );
    // 44100 frames at 44.1 kHz stay 44100 frames.
    try std.testing.expectEqual(
        @as(u64, 44100),
        try outputFrames(44100, .{ .sample_rate = 44100, .channels = 2, .bits_per_sample = 16 }, playback_format),
    );
    // Rounding is ceiling: 44100 frames at 48 kHz is 40516.875 frames out.
    try std.testing.expectEqual(
        @as(u64, 40517),
        try outputFrames(44100, .{ .sample_rate = 48000, .channels = 2, .bits_per_sample = 16 }, playback_format),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        try outputFrames(0, .{ .sample_rate = 96000, .channels = 2, .bits_per_sample = 24 }, playback_format),
    );
}
