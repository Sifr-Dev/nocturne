const std = @import("std");
const app = @import("app");

test "playback conversion duplicates mono into a bounded stereo buffer" {
    const samples = [_]i64{ -32768, 0, 32767 };
    const bytes = try app.test_convertPlaybackS16(std.testing.allocator, &samples, 1, 16);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 12), bytes.len);
    try std.testing.expectEqual(@as(u8, 0), bytes[0]);
    try std.testing.expectEqual(@as(u8, 128), bytes[1]);
    try std.testing.expectEqualSlices(u8, bytes[0..2], bytes[2..4]);
    try std.testing.expectEqualSlices(u8, bytes[8..10], bytes[10..12]);
}

test "playback conversion retains stereo sample order" {
    const samples = [_]i64{ 32767, -32768, 16384, -16384 };
    const bytes = try app.test_convertPlaybackS16(std.testing.allocator, &samples, 2, 16);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 8), bytes.len);
    try std.testing.expectEqual(@as(u8, 255), bytes[0]);
    try std.testing.expectEqual(@as(u8, 127), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0), bytes[2]);
    try std.testing.expectEqual(@as(u8, 128), bytes[3]);
}

test "unsupported multichannel playback is rejected before allocating a stereo buffer" {
    const samples = [_]i64{ 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.UnsupportedPlaybackChannels, app.test_convertPlaybackS16(std.testing.allocator, &samples, 6, 16));
    var short: [1]u8 = undefined;
    try std.testing.expectError(error.InvalidAudioBuffer, app.test_writeStereoS16Frame(&short, 0, 0, 0));
}
