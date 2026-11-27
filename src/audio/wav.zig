//! Minimal RIFF/WAVE PCM reader + writer.
//! Used for test fixtures (fed to the `flac` CLI) and for offline renders
//! (crossfade verification) of the music player.
const std = @import("std");

pub fn readFileAll(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [65536]u8 = undefined;
    while (out.items.len < max) {
        const n = try std.posix.read(fd, buf[0..]);
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

fn writeAllFd(fd: i32, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = std.os.linux.write(fd, data[off..].ptr, data.len - off);
        if (@as(i64, @bitCast(rc)) < 0) return error.WriteFailed;
        off += @intCast(rc);
    }
}

pub const Wav = struct {
    sample_rate: u32,
    channels: u16,
    bits_per_sample: u16,
    samples: []i64, // interleaved, sign-extended (8-bit stored unsigned in file)
};

pub fn write(allocator: std.mem.Allocator, path: []const u8, rate: u32, channels: u16, bps: u16, samples: []const i64) !void {
    _ = allocator;
    if (bps % 8 != 0) return error.UnsupportedBps;
    const bytes_per_sample: usize = bps / 8;
    const data_len: u32 = @intCast(samples.len * bytes_per_sample);
    var hdr: [44]u8 = undefined;
    @memcpy(hdr[0..4], "RIFF");
    writeU32LE(hdr[4..8], 36 + data_len);
    @memcpy(hdr[8..12], "WAVE");
    @memcpy(hdr[12..16], "fmt ");
    writeU32LE(hdr[16..20], 16);
    writeU16LE(hdr[20..22], 1); // PCM
    writeU16LE(hdr[22..24], channels);
    writeU32LE(hdr[24..28], rate);
    writeU32LE(hdr[28..32], rate * channels * @as(u32, @intCast(bytes_per_sample)));
    writeU16LE(hdr[32..34], channels * @as(u16, @intCast(bytes_per_sample)));
    writeU16LE(hdr[34..36], bps);
    @memcpy(hdr[36..40], "data");
    writeU32LE(hdr[40..44], data_len);
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer _ = std.c.close(fd);
    try writeAllFd(fd, &hdr);
    var buf: [8192]u8 = undefined;
    var bi: usize = 0;
    const maxv: i64 = (@as(i64, 1) << @intCast(bps - 1)) - 1;
    const minv: i64 = -(@as(i64, 1) << @intCast(bps - 1));
    for (samples) |s| {
        if (bi + bytes_per_sample > buf.len) { // flush before a sample straddles the end
            try writeAllFd(fd, buf[0..bi]);
            bi = 0;
        }
        const c = @max(minv, @min(maxv, s));
        if (bps == 8) {
            buf[bi] = @bitCast(@as(i8, @intCast(c + 128)));
            bi += 1;
        } else {
            const u: u32 = @bitCast(@as(i32, @intCast(c)));
            var k: usize = 0;
            while (k < bytes_per_sample) : (k += 1) {
                buf[bi] = @truncate(u >> @as(u5, @intCast(k * 8)));
                bi += 1;
            }
        }
    }
    if (bi > 0) try writeAllFd(fd, buf[0..bi]);
}

pub fn read(allocator: std.mem.Allocator, path: []const u8) !Wav {
    const data = try readFileAll(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(data);
    if (data.len < 44) return error.BadWav;
    if (!std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE")) return error.BadWav;
    var pos: usize = 12;
    var rate: u32 = 0;
    var channels: u16 = 0;
    var bps: u16 = 0;
    var pcm: ?[]const u8 = null;
    while (pos + 8 <= data.len) {
        const id = data[pos..][0..4];
        const len = readU32LE(data[pos + 4 ..][0..4]);
        const body = data[pos + 8 ..][0..@min(len, data.len - pos - 8)];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len >= 16) {
                channels = readU16LE(body[2..4]);
                rate = readU32LE(body[4..8]);
                bps = readU16LE(body[14..16]);
            }
        } else if (std.mem.eql(u8, id, "data")) {
            pcm = body;
        }
        pos += 8 + len + (len & 1);
    }
    const p = pcm orelse return error.BadWav;
    if (bps == 0 or channels == 0) return error.BadWav;
    if (bps % 8 != 0) return error.UnsupportedBps;
    const bytes_per_sample: usize = bps / 8;
    const n = p.len / bytes_per_sample;
    const out = try allocator.alloc(i64, n);
    errdefer allocator.free(out);
    for (out, 0..) |*s, i| {
        const b = p[i * bytes_per_sample ..][0..bytes_per_sample];
        if (bps == 8) {
            s.* = @as(i64, b[0]) - 128;
        } else {
            var u: u32 = 0;
            for (b, 0..) |byte, k| u |= @as(u32, byte) << @as(u5, @intCast(k * 8));
            // sign extend
            const bits: u6 = @intCast(bps);
            const sh: u5 = @intCast(@min(bits, 31)); // bps<=32; sign bit is bit 31 at most
            if (u & (@as(u32, 1) << (sh - 1)) != 0) {
                s.* = @intCast(@as(i32, @bitCast(u | (~@as(u32, 0) << sh))));
            } else {
                s.* = u;
            }
        }
    }
    return .{ .sample_rate = rate, .channels = channels, .bits_per_sample = bps, .samples = out };
}

fn writeU32LE(dst: []u8, v: u32) void {
    dst[0] = @truncate(v);
    dst[1] = @truncate(v >> 8);
    dst[2] = @truncate(v >> 16);
    dst[3] = @truncate(v >> 24);
}
fn writeU16LE(dst: []u8, v: u16) void {
    dst[0] = @truncate(v);
    dst[1] = @truncate(v >> 8);
}
fn readU32LE(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}
fn readU16LE(b: []const u8) u16 {
    return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
}

fn scratchPath(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const pid = std.os.linux.getpid();
    return std.fmt.allocPrint(alloc, "/tmp/cipher-{d}-{s}", .{ pid, name });
}

test "wav write/read roundtrip 16-bit stereo" {
    const alloc = std.testing.allocator;
    const path = try scratchPath(alloc, "wav_rt_test.wav");
    defer alloc.free(path);
    const samples = [_]i64{ 0, 1, -1, 32767, -32768, 12345, -12345, 100 };
    try write(alloc, path, 44100, 2, 16, &samples);
    const w = try read(alloc, path);
    defer alloc.free(w.samples);
    try std.testing.expectEqual(@as(u32, 44100), w.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), w.channels);
    try std.testing.expectEqual(@as(u16, 16), w.bits_per_sample);
    try std.testing.expectEqualSlices(i64, &samples, w.samples);
    std.debug.print("WAV_ROUNDTRIP_OK\n", .{});
}

test "wav write/read roundtrip 24-bit" {
    const alloc = std.testing.allocator;
    const path = try scratchPath(alloc, "wav_rt24_test.wav");
    defer alloc.free(path);
    const samples = [_]i64{ 0, 1, -1, 8388607, -8388608, -100000, 100000 };
    try write(alloc, path, 48000, 1, 24, &samples);
    const w = try read(alloc, path);
    defer alloc.free(w.samples);
    try std.testing.expectEqualSlices(i64, &samples, w.samples);
    std.debug.print("WAV24_ROUNDTRIP_OK\n", .{});
}
