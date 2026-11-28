//! Boundary and differential tests for the deterministic resampler.
//!
//! Grouped by concern: exact identity, stream-state independence, rational
//! position/phase correctness, passband gain, stopband rejection, pathological
//! formats, and error paths. The differential cases compare the streaming
//! implementation against a deliberately naive whole-buffer reference that
//! recomputes every tap from first principles.
const std = @import("std");
const format = @import("format");
const resampler = format.resampler;
const output_format = format.output_format;

const Resampler = resampler.Resampler;

/// Stream `input` through the resampler in fixed chunks and drain.
fn runChunked(
    allocator: std.mem.Allocator,
    source_rate: u32,
    target_rate: u32,
    channels: u8,
    input: []const f64,
    chunk_frames: usize,
) ![]f64 {
    var session = try Resampler.init(allocator, source_rate, target_rate, channels);
    defer session.deinit(allocator);
    var out: std.ArrayList(f64) = .empty;
    errdefer out.deinit(allocator);
    const frames = input.len / channels;
    var frame: usize = 0;
    while (frame < frames) {
        const count = @min(chunk_frames, frames - frame);
        const piece = try session.process(allocator, input[frame * channels ..][0 .. count * channels], false);
        defer allocator.free(piece);
        try out.appendSlice(allocator, piece);
        frame += count;
    }
    const tail = try session.process(allocator, &.{}, true);
    defer allocator.free(tail);
    try out.appendSlice(allocator, tail);
    return out.toOwnedSlice(allocator);
}

/// Independent reference: evaluate every output sample directly from the
/// definition, with no table, history window, or incremental state.
fn referenceResample(
    allocator: std.mem.Allocator,
    source_rate: u32,
    target_rate: u32,
    channels: u8,
    input: []const f64,
) ![]f64 {
    const frames = input.len / channels;
    const total = try Resampler.frameCount(frames, source_rate, target_rate);
    const half: i64 = @as(i64, resampler.tap_count / 2);
    const cutoff = if (target_rate < source_rate)
        0.5 * resampler.passband * @as(f64, @floatFromInt(target_rate)) /
            @as(f64, @floatFromInt(source_rate))
    else
        0.5 * resampler.passband;
    const out = try allocator.alloc(f64, @as(usize, @intCast(total)) * channels);
    var m: u64 = 0;
    while (m < total) : (m += 1) {
        const position = @as(f64, @floatFromInt(m)) *
            @as(f64, @floatFromInt(source_rate)) / @as(f64, @floatFromInt(target_rate));
        const center: i64 = @intFromFloat(@floor(position));
        const fraction = position - @as(f64, @floatFromInt(center));
        var weights: [resampler.tap_count]f64 = undefined;
        var sum: f64 = 0.0;
        for (&weights, 0..) |*weight, tap| {
            const distance = fraction - (@as(f64, @floatFromInt(tap)) - @as(f64, @floatFromInt(half)));
            weight.* = referenceKernel(distance, cutoff, half);
            sum += weight.*;
        }
        for (&weights) |*weight| weight.* /= sum;
        for (0..channels) |channel| {
            var accumulator: f64 = 0.0;
            for (weights, 0..) |weight, tap| {
                const index = center + @as(i64, @intCast(tap)) - half;
                if (index < 0 or index >= @as(i64, @intCast(frames))) continue;
                accumulator += input[@as(usize, @intCast(index)) * channels + channel] * weight;
            }
            out[@as(usize, @intCast(m)) * channels + channel] = accumulator;
        }
    }
    return out;
}

fn referenceKernel(distance: f64, cutoff: f64, half: i64) f64 {
    const limit = @as(f64, @floatFromInt(half));
    if (@abs(distance) >= limit) return 0.0;
    const x = distance / limit;
    const window = 0.35875 +
        0.48829 * @cos(std.math.pi * x) +
        0.14128 * @cos(2.0 * std.math.pi * x) +
        0.01168 * @cos(3.0 * std.math.pi * x);
    const angle = 2.0 * cutoff * distance;
    const sinc_value = if (@abs(angle) < 1e-12)
        @as(f64, 1.0)
    else
        @sin(std.math.pi * angle) / (std.math.pi * angle);
    return 2.0 * cutoff * sinc_value * window;
}

fn sineBuffer(allocator: std.mem.Allocator, frames: usize, rate: u32, frequency: f64) ![]f64 {
    const buffer = try allocator.alloc(f64, frames);
    errdefer allocator.free(buffer);
    for (buffer, 0..) |*sample, index| {
        const t = @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(rate));
        sample.* = 0.5 * @sin(2.0 * std.math.pi * frequency * t);
    }
    return buffer;
}

fn peakOf(samples: []const f64) f64 {
    var peak: f64 = 0.0;
    for (samples) |sample| peak = @max(peak, @abs(sample));
    return peak;
}

fn rmsOf(samples: []const f64) f64 {
    if (samples.len == 0) return 0.0;
    var sum: f64 = 0.0;
    for (samples) |sample| sum += sample * sample;
    return @sqrt(sum / @as(f64, @floatFromInt(samples.len)));
}

test "equal rates reproduce the input exactly for every chunk size" {
    const allocator = std.testing.allocator;
    const input = [_]f64{ 0.0, 0.25, -0.25, 1.0, -1.0, 0.5, 3.5e-8, -3.5e-8, 123.0 };
    const whole = try runChunked(allocator, 48000, 48000, 1, &input, input.len);
    defer allocator.free(whole);
    try std.testing.expectEqualSlices(f64, &input, whole);
    for ([_]usize{ 1, 2, 3, 8 }) |chunk| {
        const streamed = try runChunked(allocator, 48000, 48000, 1, &input, chunk);
        defer allocator.free(streamed);
        try std.testing.expectEqualSlices(f64, &input, streamed);
    }
}

test "equal-rate conversion keeps decoded 16-bit samples bit-identical" {
    const allocator = std.testing.allocator;
    const samples = [_]i64{ -32768, -1, 0, 1, 32767, 12345, -12345 };
    var expected = try allocator.alloc(u8, samples.len * 4);
    defer allocator.free(expected);
    for (samples, 0..) |sample, index| {
        const value: i16 = @intCast(sample);
        const bits: u16 = @bitCast(value);
        expected[index * 4] = @truncate(bits);
        expected[index * 4 + 1] = @truncate(bits >> 8);
        expected[index * 4 + 2] = @truncate(bits);
        expected[index * 4 + 3] = @truncate(bits >> 8);
    }
    const source = output_format.Format{ .sample_rate = 44100, .channels = 1, .bits_per_sample = 16 };
    const bytes = try output_format.convert(allocator, &samples, source, output_format.playback_format);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

test "output is independent of chunk boundaries across many ratios" {
    const allocator = std.testing.allocator;
    const input = try sineBuffer(allocator, 3000, 44100, 997.0);
    defer allocator.free(input);
    const ratios = [_][2]u32{
        .{ 44100, 48000 },
        .{ 48000, 44100 },
        .{ 96000, 44100 },
        .{ 44100, 96000 },
        .{ 8000, 48000 },
        .{ 48000, 8000 },
        .{ 44100, 22050 },
        .{ 22050, 44100 },
    };
    for (ratios) |ratio| {
        const whole = try runChunked(allocator, ratio[0], ratio[1], 1, input, input.len);
        defer allocator.free(whole);
        for ([_]usize{ 1, 13, 1024 }) |chunk| {
            const streamed = try runChunked(allocator, ratio[0], ratio[1], 1, input, chunk);
            defer allocator.free(streamed);
            try std.testing.expectEqualSlices(f64, whole, streamed);
        }
    }
}

test "streaming output matches an independent whole-buffer reference" {
    const allocator = std.testing.allocator;
    const input = try sineBuffer(allocator, 1200, 48000, 660.0);
    defer allocator.free(input);
    const ratios = [_][2]u32{ .{ 48000, 44100 }, .{ 44100, 48000 }, .{ 96000, 48000 } };
    for (ratios) |ratio| {
        const streamed = try runChunked(allocator, ratio[0], ratio[1], 1, input, 97);
        defer allocator.free(streamed);
        const reference = try referenceResample(allocator, ratio[0], ratio[1], 1, input);
        defer allocator.free(reference);
        try std.testing.expectEqual(reference.len, streamed.len);
        for (reference, streamed) |expected, actual| {
            try std.testing.expectApproxEqAbs(expected, actual, 1e-12);
        }
    }
}

test "output frame counts match the rational ratio for every rate pair" {
    const allocator = std.testing.allocator;
    const input = try sineBuffer(allocator, 1000, 44100, 440.0);
    defer allocator.free(input);
    const targets = [_]u32{ 8000, 22050, 44100, 48000, 96000, 192000 };
    for (targets) |target| {
        const out = try runChunked(allocator, 44100, target, 1, input, 256);
        defer allocator.free(out);
        try std.testing.expectEqual(try Resampler.frameCount(1000, 44100, target), out.len);
    }
}

test "a sustained passband tone keeps its amplitude after conversion" {
    const allocator = std.testing.allocator;
    const input = try sineBuffer(allocator, 8000, 44100, 1000.0);
    defer allocator.free(input);
    const pairs = [_][2]u32{ .{ 44100, 48000 }, .{ 48000, 44100 }, .{ 96000, 44100 } };
    for (pairs) |pair| {
        const out = try runChunked(allocator, pair[0], pair[1], 1, input, 311);
        defer allocator.free(out);
        // Ignore the filter warm-up and drain edges.
        const middle = out[300 .. out.len - 300];
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), peakOf(middle), 0.02);
    }
}

test "content above the target Nyquist limit is rejected when downsampling" {
    const allocator = std.testing.allocator;
    // 20 kHz cannot survive 44.1 kHz -> 22.05 kHz, whose Nyquist is 11.025 kHz.
    const input = try sineBuffer(allocator, 20000, 44100, 20000.0);
    defer allocator.free(input);
    const out = try runChunked(allocator, 44100, 22050, 1, input, 512);
    defer allocator.free(out);
    const middle = out[2000 .. out.len - 2000];
    try std.testing.expect(rmsOf(middle) < 0.01);
}

test "downsampling attenuates an aliasing tone by more than 40 dB" {
    const allocator = std.testing.allocator;
    const input = try sineBuffer(allocator, 20000, 48000, 30000.0);
    defer allocator.free(input);
    // 30 kHz folds below the new Nyquist of 24 kHz; a naive decimator would
    // leave a full-amplitude alias, so this is the case that distinguishes a
    // real anti-alias filter from sample dropping.
    const out = try runChunked(allocator, 48000, 24000, 1, input, 400);
    defer allocator.free(out);
    const middle = out[2000 .. out.len - 2000];
    const ratio = rmsOf(middle) / (0.5 / @sqrt(@as(f64, 2.0)));
    try std.testing.expect(ratio < 0.01);
}

test "mono and stereo produce the same per-channel content" {
    const allocator = std.testing.allocator;
    const mono = try sineBuffer(allocator, 2000, 48000, 700.0);
    defer allocator.free(mono);
    const stereo = try allocator.alloc(f64, mono.len * 2);
    defer allocator.free(stereo);
    for (mono, 0..) |sample, index| {
        stereo[index * 2] = sample;
        stereo[index * 2 + 1] = sample;
    }
    const from_mono = try runChunked(allocator, 48000, 44100, 1, mono, 128);
    defer allocator.free(from_mono);
    const from_stereo = try runChunked(allocator, 48000, 44100, 2, stereo, 128);
    defer allocator.free(from_stereo);
    try std.testing.expectEqual(from_mono.len * 2, from_stereo.len);
    for (from_mono, 0..) |sample, index| {
        try std.testing.expectEqual(sample, from_stereo[index * 2]);
        try std.testing.expectEqual(sample, from_stereo[index * 2 + 1]);
    }
}

test "one-frame and empty streams are handled without drift" {
    const allocator = std.testing.allocator;
    var session = try Resampler.init(allocator, 44100, 48000, 1);
    defer session.deinit(allocator);
    const one = [_]f64{0.5};
    const first = try session.process(allocator, &one, false);
    defer allocator.free(first);
    try std.testing.expectEqual(@as(usize, 0), first.len);
    const tail = try session.process(allocator, &.{}, true);
    defer allocator.free(tail);
    try std.testing.expectEqual(@as(usize, 2), tail.len);

    var empty = try Resampler.init(allocator, 44100, 48000, 1);
    defer empty.deinit(allocator);
    const none = try empty.process(allocator, &.{}, true);
    defer allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "a fully drained stream stays drained" {
    const allocator = std.testing.allocator;
    var session = try Resampler.init(allocator, 48000, 44100, 2);
    defer session.deinit(allocator);
    const input = [_]f64{ 0.1, -0.1, 0.2, -0.2 };
    const first = try session.process(allocator, &input, false);
    defer allocator.free(first);
    const tail = try session.process(allocator, &.{}, true);
    defer allocator.free(tail);
    const again = try session.process(allocator, &.{}, true);
    defer allocator.free(again);
    try std.testing.expectEqual(@as(usize, 0), again.len);
    // Input after the drain is a programming error, not silent data loss.
    try std.testing.expectError(error.StreamAlreadyFinished, session.process(allocator, &input, true));
    try std.testing.expectError(error.StreamAlreadyFinished, session.process(allocator, &input, false));
}

test "invalid formats and malformed buffers are rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidAudioFormat, Resampler.init(allocator, 0, 48000, 2));
    try std.testing.expectError(error.InvalidAudioFormat, Resampler.init(allocator, 48000, 0, 2));
    try std.testing.expectError(error.InvalidAudioFormat, Resampler.init(allocator, 48000, 48000, 0));
    try std.testing.expectError(error.UnsupportedSampleRate, Resampler.init(allocator, 2_000_000, 48000, 2));
    try std.testing.expectError(error.InvalidAudioFormat, Resampler.frameCount(1, 0, 48000));
    try std.testing.expectError(error.InvalidAudioFormat, Resampler.frameCount(1, 48000, 0));

    var session = try Resampler.init(allocator, 48000, 44100, 2);
    defer session.deinit(allocator);
    try std.testing.expectError(error.InvalidAudioBuffer, session.process(allocator, &[_]f64{0.1}, false));
    try std.testing.expectError(
        error.InvalidAudioSample,
        session.process(allocator, &[_]f64{ std.math.nan(f64), 0.0 }, false),
    );
    try std.testing.expectError(
        error.InvalidAudioSample,
        session.process(allocator, &[_]f64{ std.math.inf(f64), 0.0 }, false),
    );
}

test "extreme ratios still terminate and stay chunk-invariant" {
    const allocator = std.testing.allocator;
    const input = try sineBuffer(allocator, 512, 44100, 100.0);
    defer allocator.free(input);
    const pairs = [_][2]u32{ .{ 192000, 8000 }, .{ 8000, 192000 }, .{ 384000, 44100 } };
    for (pairs) |pair| {
        var session = try Resampler.init(allocator, pair[0], pair[1], 1);
        defer session.deinit(allocator);
        const out = try session.process(allocator, input, false);
        defer allocator.free(out);
        const tail = try session.process(allocator, &.{}, true);
        defer allocator.free(tail);
        const expected = try Resampler.frameCount(512, pair[0], pair[1]);
        try std.testing.expectEqual(@as(usize, @intCast(expected)), out.len + tail.len);
        for (out) |sample| try std.testing.expect(std.math.isFinite(sample));
        for (tail) |sample| try std.testing.expect(std.math.isFinite(sample));
    }
}

test "degenerate ratios are rejected instead of building a collapsed kernel" {
    const allocator = std.testing.allocator;
    // 44100 -> 1 leaves a single output per 44100 input frames; a kernel that
    // narrow is numerically useless, so it must be refused rather than
    // silently normalised into noise.
    try std.testing.expectError(error.UnsupportedRatio, Resampler.init(allocator, 44100, 1, 1));
    try std.testing.expectError(error.UnsupportedRatio, Resampler.init(allocator, 1, 44100, 1));
    try std.testing.expectError(error.UnsupportedRatio, Resampler.init(allocator, 400000, 8, 2));
}

test "24-bit and 32-bit sources reach full scale without clipping artifacts" {
    const allocator = std.testing.allocator;
    for ([_]u8{ 16, 24, 32 }) |bits| {
        const bound = output_format.sourceBound(bits);
        const samples = [_]i64{ -bound, bound - 1, 0, 1, -1 };
        const source = output_format.Format{ .sample_rate = 44100, .channels = 1, .bits_per_sample = bits };
        const bytes = try output_format.convert(allocator, &samples, source, output_format.playback_format);
        defer allocator.free(bytes);
        const first: i16 = @bitCast(@as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8));
        const second: i16 = @bitCast(@as(u16, bytes[4]) | (@as(u16, bytes[5]) << 8));
        try std.testing.expectEqual(@as(i16, -32768), first);
        try std.testing.expectEqual(@as(i16, 32767), second);
    }
}

test "samples outside the declared bit depth are rejected" {
    const allocator = std.testing.allocator;
    const source = output_format.Format{ .sample_rate = 44100, .channels = 1, .bits_per_sample = 16 };
    try std.testing.expectError(
        error.InvalidAudioSample,
        output_format.convert(allocator, &[_]i64{40000}, source, output_format.playback_format),
    );
    try std.testing.expectError(
        error.InvalidAudioSample,
        output_format.convert(allocator, &[_]i64{-40000}, source, output_format.playback_format),
    );
}

test "resampled output is deterministic across repeated runs" {
    const allocator = std.testing.allocator;
    const input = try sineBuffer(allocator, 5000, 44100, 1234.0);
    defer allocator.free(input);
    const first = try runChunked(allocator, 44100, 48000, 2, input, 1);
    defer allocator.free(first);
    const second = try runChunked(allocator, 44100, 48000, 2, input, 256);
    defer allocator.free(second);
    try std.testing.expectEqualSlices(f64, first, second);
    // Byte-for-byte identical output after quantisation, too.
    const source = output_format.Format{ .sample_rate = 44100, .channels = 1, .bits_per_sample = 16 };
    const ints = try allocator.alloc(i64, input.len);
    defer allocator.free(ints);
    for (input, 0..) |sample, index| {
        ints[index] = @intFromFloat(@round(sample * 32767.0));
    }
    const bytes_a = try output_format.convert(allocator, ints, source, output_format.playback_format);
    defer allocator.free(bytes_a);
    const bytes_b = try output_format.convert(allocator, ints, source, output_format.playback_format);
    defer allocator.free(bytes_b);
    try std.testing.expectEqualSlices(u8, bytes_a, bytes_b);
}
