//! Playback engine: FLAC -> f64 PCM, sample-exact linear crossfade, s16
//! quantization, offline WAV render (tests) and PulseAudio-simple output.
const std = @import("std");
const flac = @import("flac.zig");
const wav = @import("wav.zig");

pub const Track = struct {
    path: []const u8,
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,
    /// interleaved raw sample values as f64
    samples: []f64,
    comments: []flac.Comment,
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Track) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    pub fn durationSec(self: *const Track) f64 {
        return @as(f64, @floatFromInt(self.samples.len)) / @as(f64, @floatFromInt(self.channels)) / @as(f64, @floatFromInt(self.sample_rate));
    }

    pub fn comment(self: *const Track, key: []const u8) ?[]const u8 {
        for (self.comments) |c| if (std.mem.eql(u8, c.key, key)) return c.value;
        return null;
    }
};

pub fn loadTrack(allocator: std.mem.Allocator, path: []const u8) !Track {
    var dec = try flac.decodeFile(allocator, path);
    const a = dec.arena.allocator();
    const samples = try a.alloc(f64, dec.samples.len);
    for (dec.samples, 0..) |s, i| samples[i] = @floatFromInt(s);
    return .{
        .path = try a.dupe(u8, path),
        .sample_rate = dec.sample_rate,
        .channels = dec.channels,
        .bits_per_sample = dec.bits_per_sample,
        .samples = samples,
        .comments = dec.comments,
        .arena = dec.arena,
        .allocator = allocator,
    };
}

/// Linear crossfade of two interleaved PCM streams (f64, raw domain).
/// `overlap_frames` frames of `b` fade in over the tail of `a`.
/// Returns a newly allocated interleaved buffer of length
/// a.len + b.len - overlap_frames*ch (frames).
pub fn crossfade(allocator: std.mem.Allocator, a: []const f64, b: []const f64, overlap_frames: usize, ch: u8) ![]f64 {
    const chu: usize = ch;
    if (overlap_frames == 0 or a.len == 0 or b.len == 0) {
        // plain concatenation
        const out = try allocator.alloc(f64, a.len + b.len);
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len..], b);
        return out;
    }
    const ov = @min(overlap_frames, a.len / chu, b.len / chu);
    const out_len = a.len + b.len - ov * chu;
    const out = try allocator.alloc(f64, out_len);
    errdefer allocator.free(out);
    @memcpy(out[0 .. a.len - ov * chu], a[0 .. a.len - ov * chu]);
    var f: usize = 0;
    while (f < ov) : (f += 1) {
        const g: f64 = @as(f64, @floatFromInt(f + 1)) / @as(f64, @floatFromInt(ov)); // 1/ov .. 1
        var c: usize = 0;
        while (c < chu) : (c += 1) {
            const ai = a.len - ov * chu + f * chu + c;
            const bi = f * chu + c;
            out[a.len - ov * chu + f * chu + c] = a[ai] * (1.0 - g) + b[bi] * g;
        }
    }
    @memcpy(out[a.len ..], b[ov * chu ..]);
    return out;
}

/// Quantize f64 raw samples to s16 (with clipping), little-endian byte output.
pub fn quantizeS16LE(out: []u8, samples: []const f64, bps: u8) void {
    const maxv: f64 = @floatFromInt((@as(i64, 1) << @intCast(bps - 1)) - 1);
    const minv: f64 = -@as(f64, @floatFromInt(@as(i64, 1) << @intCast(bps - 1)));
    for (samples, 0..) |s, i| {
        const c = @max(minv, @min(maxv, s));
        const q: i16 = @intFromFloat(@round(c / maxv * 32767.0));
        const u: u16 = @bitCast(q);
        out[i * 2] = @truncate(u);
        out[i * 2 + 1] = @truncate(u >> 8);
    }
}

/// Offline render: crossfade two decoded tracks and write a 16-bit WAV.
/// Used by tests to verify sample-exact output.
pub fn renderCrossfadeWav(allocator: std.mem.Allocator, out_path: []const u8, a: *Track, b: *Track, overlap_frames: usize) !usize {
    if (a.channels != b.channels) return error.ChannelMismatch;
    const mixed = try crossfade(allocator, a.samples, b.samples, overlap_frames, a.channels);
    defer allocator.free(mixed);
    // wav.write takes i64; quantize the f64 mix into a temp i64 buffer first
    const tmp = try allocator.alloc(i64, mixed.len);
    defer allocator.free(tmp);
    const maxv: f64 = @floatFromInt((@as(i64, 1) << @intCast(a.bits_per_sample - 1)) - 1);
    for (mixed, 0..) |s, i| {
        const c = @max(-maxv, @min(maxv, s));
        tmp[i] = @as(i64, @intFromFloat(@round(c / maxv * 32767.0)));
    }
    try wav.write(allocator, out_path, a.sample_rate, a.channels, 16, tmp);
    return mixed.len;
}

test "crossfade is sample-exact vs independent f64 reference + WAV render" {
    const alloc = std.testing.allocator;
    const ch: u8 = 2;
    const chu: usize = ch;
    const a_len = 1000 * chu; // 1000 frames
    const b_len = 800 * chu;
    const ov = 200; // frames
    const a = try alloc.alloc(f64, a_len);
    defer alloc.free(a);
    const b = try alloc.alloc(f64, b_len);
    defer alloc.free(b);
    for (a, 0..) |*s, i| s.* = @as(f64, @floatFromInt(@as(i64, @intCast(i % 251)) - 125)) * 100.0;
    for (b, 0..) |*s, i| s.* = @as(f64, @floatFromInt(@as(i64, @intCast(i % 197)) - 98)) * -50.0;
    const out = try crossfade(alloc, a, b, ov, ch);
    defer alloc.free(out);
    // independent reference
    const exp_len = a_len + b_len - ov * chu;
    try std.testing.expectEqual(exp_len, out.len);
    for (0..a_len - ov * chu) |i| try std.testing.expectEqual(a[i], out[i]);
    for (0..ov) |f| {
        const g: f64 = @as(f64, @floatFromInt(f + 1)) / @as(f64, @floatFromInt(ov));
        for (0..chu) |c| {
            const ai = a_len - ov * chu + f * chu + c;
            const bi = f * chu + c;
            const exp = a[ai] * (1.0 - g) + b[bi] * g;
            try std.testing.expectEqual(exp, out[a_len - ov * chu + f * chu + c]);
        }
    }
    for (ov * chu..b_len) |i| try std.testing.expectEqual(b[i], out[a_len + i - ov * chu]);
    // WAV render path: quantize and compare exactly
    var track_a = Track{ .path = "a", .sample_rate = 44100, .channels = ch, .bits_per_sample = 16, .samples = a, .comments = &.{}, .arena = undefined, .allocator = alloc };
    var track_b = Track{ .path = "b", .sample_rate = 44100, .channels = ch, .bits_per_sample = 16, .samples = b, .comments = &.{}, .arena = undefined, .allocator = alloc };
    const pid2 = std.os.linux.getpid();
    const path = try std.fmt.allocPrint(alloc, "/tmp/cipher-{d}-crossfade_test.wav", .{pid2});
    defer alloc.free(path);
    const n = try renderCrossfadeWav(alloc, path, &track_a, &track_b, ov);
    try std.testing.expectEqual(exp_len, n);
    const w = try wav.read(alloc, path);
    defer alloc.free(w.samples);
    try std.testing.expectEqual(exp_len, w.samples.len);
    // reference quantization (same formula, computed independently here)
    const maxv: f64 = 32767.0;
    for (out, 0..) |s, i| {
        const c = @max(-maxv, @min(maxv, s));
        const exp: i64 = @intFromFloat(@round(c / maxv * 32767.0));
        try std.testing.expectEqual(exp, w.samples[i]);
    }
    std.debug.print("CROSSFADE_SAMPLE_EXACT_OK frames={d} overlap={d}\n", .{ exp_len / ch, ov });
}
