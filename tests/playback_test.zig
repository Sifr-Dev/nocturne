const std = @import("std");
const app = @import("app");

test "playback conversion duplicates mono into a bounded stereo buffer" {
    const samples = [_]i64{ -32768, 0, 32767 };
    const bytes = try app.test_convertToPlaybackFormat(std.testing.allocator, &samples, 44100, 1, 16);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 12), bytes.len);
    try std.testing.expectEqual(@as(u8, 0), bytes[0]);
    try std.testing.expectEqual(@as(u8, 128), bytes[1]);
    try std.testing.expectEqualSlices(u8, bytes[0..2], bytes[2..4]);
    try std.testing.expectEqualSlices(u8, bytes[8..10], bytes[10..12]);
}

test "playback conversion retains stereo sample order" {
    const samples = [_]i64{ 32767, -32768, 16384, -16384 };
    const bytes = try app.test_convertToPlaybackFormat(std.testing.allocator, &samples, 44100, 2, 16);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 8), bytes.len);
    try std.testing.expectEqual(@as(u8, 255), bytes[0]);
    try std.testing.expectEqual(@as(u8, 127), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0), bytes[2]);
    try std.testing.expectEqual(@as(u8, 128), bytes[3]);
}

test "unsupported multichannel playback is rejected before allocating a stereo buffer" {
    const samples = [_]i64{ 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.UnsupportedPlaybackChannels, app.test_convertToPlaybackFormat(std.testing.allocator, &samples, 44100, 6, 16));
}

test "a 48 kHz source is resampled to the 44.1 kHz playback format" {
    const allocator = std.testing.allocator;
    const frames: usize = 48000;
    const samples = try allocator.alloc(i64, frames);
    defer allocator.free(samples);
    for (samples, 0..) |*sample, index| {
        const t = @as(f64, @floatFromInt(index)) / 48000.0;
        sample.* = @intFromFloat(@round(0.5 * @sin(2.0 * std.math.pi * 440.0 * t) * 32767.0));
    }
    const bytes = try app.test_convertToPlaybackFormat(allocator, samples, 48000, 1, 16);
    defer allocator.free(bytes);
    // 48000 frames at 48 kHz become 44100 stereo frames at 44.1 kHz.
    try std.testing.expectEqual(@as(usize, 44100 * 4), bytes.len);
}

test "a 96 kHz multichannel source is still rejected after rate conversion is available" {
    const samples = [_]i64{ 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(
        error.UnsupportedPlaybackChannels,
        app.test_convertToPlaybackFormat(std.testing.allocator, &samples, 96000, 6, 24),
    );
}
