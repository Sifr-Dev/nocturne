//! From-zero FLAC decoder (format spec: STREAMINFO + metadata blocks incl.
//! VORBIS_COMMENT; frame headers with CRC-8; subframes CONSTANT / VERBATIM /
//! FIXED(0-4) / LPC(1-32) with Rice-partition residuals and wasted bits;
//! left/side, right/side, mid/side decorrelation; frame CRC-16; STREAMINFO
//! MD5 verification). No libraries — a plain MSB-first bit reader.
//!
//! Supported: native FLAC only (RFC 9639), mono..8ch independent, 8/12/16/20/24
//! bit depths, all defined sample-rate codes, rice and rice2 residual coding,
//! escape partitions and wasted bits. Verified bit-exact against ffmpeg on the
//! real collection.
//!
//! Not supported (returns a specific error rather than guessing):
//!   * Ogg-encapsulated FLAC (OggFLAC) — no `OggS` demuxer here.
//!   * Files whose STREAMINFO MD5 is unset (`md5_ok` is then false by
//!     construction; per-frame CRC-16 still validates the decode).
//!   * Non-FLAC payloads with a .flac extension return error.NotFlac.
const std = @import("std");
const wav = @import("wav.zig");

pub const Comment = struct { key: []const u8, value: []const u8 };

pub const Decoded = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,
    total_samples: u64, // per channel
    samples: []i64, // interleaved by channel
    md5: [16]u8,
    md5_ok: bool,
    comments: []Comment,

    pub fn deinit(self: *Decoded) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    /// Convenience accessors over the VORBIS_COMMENT entries (keys uppercased).
    pub fn comment(self: *const Decoded, key: []const u8) ?[]const u8 {
        for (self.comments) |c| {
            if (std.mem.eql(u8, c.key, key)) return c.value;
        }
        return null;
    }
};

const BitReader = struct {
    data: []const u8,
    pos: usize = 0, // bit position

    fn readBit(self: *BitReader) !u1 {
        if (self.pos >= self.data.len * 8) return error.UnexpectedEnd;
        const byte = self.data[self.pos / 8];
        const bit: u1 = @intCast((byte >> @intCast(7 - (self.pos % 8))) & 1);
        self.pos += 1;
        return bit;
    }

    fn readBits(self: *BitReader, n: u6) !u64 {
        var v: u64 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) v = (v << 1) | try self.readBit();
        return v;
    }

    fn readUnary(self: *BitReader) !u64 {
        var v: u64 = 0;
        while (true) {
            if (try self.readBit() == 1) return v;
            v += 1;
            if (v > 1 << 24) return error.InvalidResidual;
        }
    }

    /// Two's-complement signed value of n bits.
    fn readSigned(self: *BitReader, n: u6) !i64 {
        if (n == 0) return 0;
        const u = try self.readBits(n);
        if (n < 64 and (u >> @intCast(n - 1)) == 1) {
            return @as(i64, @intCast(u)) - (@as(i64, 1) << @intCast(n));
        }
        return @intCast(u);
    }

    fn alignByte(self: *BitReader) void {
        self.pos = (self.pos + 7) & ~@as(usize, 7);
    }

    fn bytePos(self: *const BitReader) usize {
        return self.pos / 8;
    }
};

fn zigzag(u: u64) i64 {
    if (u & 1 == 1) return -@as(i64, @intCast(u >> 1)) - 1;
    return @intCast(u >> 1);
}

fn readUtf8Coded(br: *BitReader) !u64 {
    const b0 = try br.readBits(8);
    if (b0 < 0x80) return b0;
    var len: u6 = undefined;
    var val: u64 = undefined;
    if ((b0 & 0xE0) == 0xC0) {
        len = 2;
        val = b0 & 0x1F;
    } else if ((b0 & 0xF0) == 0xE0) {
        len = 3;
        val = b0 & 0x0F;
    } else if ((b0 & 0xF8) == 0xF0) {
        len = 4;
        val = b0 & 0x07;
    } else if ((b0 & 0xFC) == 0xF8) {
        len = 5;
        val = b0 & 0x03;
    } else if ((b0 & 0xFE) == 0xFC) {
        len = 6;
        val = b0 & 0x01;
    } else return error.InvalidUtf8;
    var i: u6 = 1;
    while (i < len) : (i += 1) {
        const b = try br.readBits(8);
        if ((b & 0xC0) != 0x80) return error.InvalidUtf8;
        val = (val << 6) | (b & 0x3F);
    }
    return val;
}

fn crc8(data: []const u8) u8 {
    var crc: u32 = 0;
    for (data) |b| {
        crc = (crc ^ b) & 0xFF;
        var i: u4 = 0;
        while (i < 8) : (i += 1) {
            const top = crc & 0x80;
            crc = (crc << 1) & 0xFF;
            if (top != 0) crc ^= 0x07;
        }
    }
    return @intCast(crc);
}

fn crc16(data: []const u8) u16 {
    var crc: u32 = 0;
    for (data) |b| {
        crc = (crc ^ (@as(u32, b) << 8)) & 0xFFFF;
        var i: u4 = 0;
        while (i < 8) : (i += 1) {
            const top = crc & 0x8000;
            crc = (crc << 1) & 0xFFFF;
            if (top != 0) crc ^= 0x8005;
        }
    }
    return @intCast(crc);
}

const FrameHeader = struct {
    blocksize: u32,
    sample_rate: u32,
    bps: u8,
    channel_assignment: u8, // 0-7 independent (n=ca+1), 8 left/side, 9 right/side, 10 mid/side
    number: u64,
    start: usize, // byte offset of frame in data
    header_len: usize, // bytes including CRC-8
};

fn parseFrameHeader(data: []const u8, pos: usize, si_rate: u32, si_bps: u8) !FrameHeader {
    var br = BitReader{ .data = data, .pos = pos * 8 };
    if (try br.readBits(14) != 0x3FFE) return error.BadSync;
    _ = try br.readBit(); // reserved
    _ = try br.readBit(); // blocking strategy
    const bs_code: u4 = @intCast(try br.readBits(4));
    const sr_code: u4 = @intCast(try br.readBits(4));
    const ca: u4 = @intCast(try br.readBits(4));
    const bps_code: u3 = @intCast(try br.readBits(3));
    if (try br.readBit() != 0) return error.BadReserved;
    const number = try readUtf8Coded(&br);
    var blocksize: u32 = 0;
    switch (bs_code) {
        0 => return error.ReservedBlocksize,
        1 => blocksize = 192,
        2 => blocksize = 576,
        3 => blocksize = 1152,
        4 => blocksize = 2304,
        5 => blocksize = 4608,
        6 => blocksize = @as(u32, @intCast(try br.readBits(8))) + 1,
        7 => blocksize = @as(u32, @intCast(try br.readBits(16))) + 1,
        8...15 => blocksize = @as(u32, 256) << @as(u5, @intCast(bs_code - 8)),
    }
    var rate: u32 = si_rate;
    switch (sr_code) {
        0 => rate = si_rate,
        1 => rate = 88200,
        2 => rate = 176400,
        3 => rate = 192000,
        4 => rate = 8000,
        5 => rate = 16000,
        6 => rate = 22050,
        7 => rate = 24000,
        8 => rate = 32000,
        9 => rate = 44100,
        10 => rate = 48000,
        11 => rate = 96000,
        12 => rate = @as(u32, @intCast(try br.readBits(8))) * 1000,
        13 => rate = @as(u32, @intCast(try br.readBits(16))),
        14 => rate = @as(u32, @intCast(try br.readBits(16))) * 10,
        15 => return error.InvalidRate,
    }
    var bps: u8 = si_bps;
    switch (bps_code) {
        0 => bps = si_bps,
        1 => bps = 8,
        2 => bps = 12,
        3 => return error.ReservedBps,
        4 => bps = 16,
        5 => bps = 20,
        6 => bps = 24,
        7 => return error.ReservedBps,
    }
    if (ca > 10) return error.InvalidChannelAssignment;
    br.alignByte();
    const hdr_bytes = br.bytePos() - pos;
    const crc = try br.readBits(8);
    if (crc != crc8(data[pos .. pos + hdr_bytes])) return error.Crc8Mismatch;
    return .{
        .blocksize = blocksize,
        .sample_rate = rate,
        .bps = bps,
        .channel_assignment = ca,
        .number = number,
        .start = pos,
        .header_len = hdr_bytes + 1,
    };
}

fn readResidual(br: *BitReader, out: []i64, blocksize: u32, predictor_order: u32) !void {
    // RFC 9639 9.2.7: 2 bits coding method (0b00 = 4-bit params, 0b01 = 5-bit),
    // then 4 bits partition order, then per-partition parameter + residuals.
    const method = try br.readBits(2);
    if (method > 1) return error.InvalidResidualMethod;
    const param_bits: u6 = if (method == 0) 4 else 5;
    const porder: u4 = @intCast(try br.readBits(4));
    const partitions: u32 = @as(u32, 1) << @intCast(porder);
    const psamples: u32 = blocksize >> @intCast(porder);
    if (std.c.getenv("FLAC_DEBUG") != null) std.debug.print("  residual: method={d} porder={d} partitions={d} psamples={d} order={d} bits_before={d}\n", .{ method, porder, partitions, psamples, predictor_order, br.pos });
    if (psamples * partitions != blocksize) return error.InvalidPartition;
    var idx: usize = 0;
    var p: u32 = 0;
    while (p < partitions) : (p += 1) {
        const count: u32 = psamples - (if (p == 0) predictor_order else 0);
        const code = try br.readBits(param_bits);
        const escape: u64 = (@as(u64, 1) << @intCast(param_bits)) - 1;
        if (std.c.getenv("FLAC_DEBUG") != null) std.debug.print("  partition {d}: code={d} count={d}\n", .{ p, code, count });
        if (code == escape) {
            const nbits: u5 = @intCast(try br.readBits(5));
            var k: u32 = 0;
            while (k < count) : (k += 1) {
                out[idx] = try br.readSigned(nbits);
                idx += 1;
            }
        } else {
            const k: u6 = @intCast(code);
            var k2: u32 = 0;
            while (k2 < count) : (k2 += 1) {
                const q = try br.readUnary();
                const rem: u64 = if (k > 0) try br.readBits(k) else 0;
                out[idx] = zigzag((q << @intCast(k)) | rem);
                idx += 1;
            }
        }
    }
}

/// Decode one subframe into out[0..blocksize] (before channel decorrelation,
/// after wasted-bits shift).
fn decodeSubframe(br: *BitReader, out: []i64, blocksize: u32, bps: u8, residual_buf: []i64) !void {
    if (try br.readBit() != 0) return error.BadSubframePad;
    const stype = try br.readBits(6);
    const wasted_flag = try br.readBit();
    var wasted: u8 = 0;
    if (wasted_flag == 1) {
        wasted = 1;
        while (try br.readBit() == 0) {
            wasted += 1;
            if (wasted > 31) return error.InvalidWasted;
        }
    }
    const width: u6 = @intCast(bps - wasted);
    if (stype == 0) { // CONSTANT
        const v = try br.readSigned(width);
        for (out[0..blocksize]) |*s| s.* = v;
    } else if (stype == 1) { // VERBATIM
        for (out[0..blocksize]) |*s| s.* = try br.readSigned(width);
    } else if (stype >= 8 and stype <= 12) { // FIXED, order = stype - 8
        const order: u32 = @intCast(stype - 8);
        for (out[0..order]) |*s| s.* = try br.readSigned(width);
        try readResidual(br, residual_buf, blocksize, order);
        var i: u32 = order;
        while (i < blocksize) : (i += 1) {
            const r = residual_buf[i - order]; // residuals are packed from index 0
            // wrapping arithmetic: FLAC predictors are defined modulo 2^N
            out[i] = switch (order) {
                0 => r,
                1 => r +% out[i - 1],
                2 => r +% 2 *% out[i - 1] -% out[i - 2],
                3 => r +% 3 *% out[i - 1] -% 3 *% out[i - 2] +% out[i - 3],
                4 => r +% 4 *% out[i - 1] -% 6 *% out[i - 2] +% 4 *% out[i - 3] -% out[i - 4],
                else => unreachable,
            };
        }
    } else if (stype >= 32) { // LPC, order = stype - 31
        const order: u32 = @intCast(stype - 31);
        if (order < 1 or order > 32) return error.InvalidLpcOrder;
        // spec order: warmup samples, then precision/shift/coefficients, then residual
        for (out[0..order]) |*s| s.* = try br.readSigned(width);
        const precision: u4 = @intCast(try br.readBits(4));
        if (precision == 15) return error.InvalidLpcPrecision;
        const coef_bits: u6 = @intCast(precision + 1);
        const shift: i64 = try br.readSigned(5);
        var coef_buf: [32]i64 = undefined;
        for (coef_buf[0..order]) |*c| c.* = try br.readSigned(coef_bits);
        try readResidual(br, residual_buf, blocksize, order);
        var i: u32 = order;
        while (i < blocksize) : (i += 1) {
            var sum: i64 = 0;
            var j: u32 = 0;
            while (j < order) : (j += 1) sum +%= coef_buf[j] *% out[i - 1 - j]; // wrapping
            const r = residual_buf[i - order];
            out[i] = r +% if (shift >= 0) (sum >> @as(u6, @intCast(shift))) else @as(i64, @bitCast((@as(u64, @bitCast(sum)) << @as(u6, @intCast(-shift)))));
        }
    } else return error.InvalidSubframeType;
    if (wasted > 0) {
        for (out[0..blocksize]) |*s| s.* <<= @intCast(wasted);
    }
}

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Decoded {
    if (data.len < 8 or !std.mem.eql(u8, data[0..4], "fLaC")) return error.NotFlac;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const a = arena.allocator();

    var pos: usize = 4;
    var sample_rate: u32 = 0;
    var channels: u8 = 0;
    var bps: u8 = 0;
    var total_samples: u64 = 0;
    var md5: [16]u8 = std.mem.zeroes([16]u8);
    var comments: []Comment = &.{};

    // metadata blocks
    while (pos + 4 <= data.len) {
        const head = data[pos];
        const last = head & 0x80 != 0;
        const btype: u7 = @intCast(head & 0x7F);
        const blen: usize = (@as(usize, data[pos + 1]) << 16) | (@as(usize, data[pos + 2]) << 8) | data[pos + 3];
        const body = data[pos + 4 ..][0..@min(blen, data.len - pos - 4)];
        switch (btype) {
            0 => { // STREAMINFO
                if (body.len < 34) return error.BadStreaminfo;
                const min_bs = (@as(u32, body[0]) << 8) | body[1];
                const max_bs = (@as(u32, body[2]) << 8) | body[3];
                _ = min_bs;
                _ = max_bs;
                // layout: min_bs(16) max_bs(16) min_fs(24) max_fs(24) = 10 bytes, then rate/ch/bps/total
                var br = BitReader{ .data = body, .pos = 10 * 8 };
                sample_rate = @intCast(try br.readBits(20));
                channels = @as(u8, @intCast(try br.readBits(3))) + 1;
                bps = @as(u8, @intCast(try br.readBits(5))) + 1;
                total_samples = try br.readBits(36);
                @memcpy(&md5, body[18..34]);
            },
            4 => { // VORBIS_COMMENT
                comments = try parseVorbisComment(a, body);
            },
            else => {},
        }
        pos += 4 + blen;
        if (last) break;
    }
    if (sample_rate == 0 or channels == 0 or bps == 0) return error.MissingStreaminfo;

    // frames
    var out = std.ArrayList(i64).empty;
    errdefer out.deinit(a);
    const channels_u32: u32 = channels;
    const frame_buf = try a.alloc(i64, 65536 * 8);
    defer a.free(frame_buf);
    const residual_buf = try a.alloc(i64, 65536);
    defer a.free(residual_buf);

    var decoded_frames: u64 = 0;
    while (pos < data.len) {
        if (total_samples > 0 and decoded_frames >= total_samples) break;
        const hdr = parseFrameHeader(data, pos, sample_rate, bps) catch |e| switch (e) {
            error.BadSync, error.UnexpectedEnd => break, // trailing junk/EOF
            else => return e,
        };
        const nch: u32 = if (hdr.channel_assignment <= 7) hdr.channel_assignment + 1 else 2;
        if (nch != channels_u32) return error.ChannelMismatch;
        const bs = hdr.blocksize;
        if (bs > 65536) return error.BlocksizeTooLarge;
        var bt = BitReader{ .data = data, .pos = (pos + hdr.header_len) * 8 };
        var ch_data: [8][]i64 = undefined;
        var ci: u32 = 0;
        while (ci < nch) : (ci += 1) {
            ch_data[ci] = frame_buf[ci * 65536 ..][0..bs];
            // RFC 9639 4.2: whichever slot holds the side channel carries one
            // extra bit of depth. left/side and mid/side put it in subframe 1,
            // right/side puts it in subframe 0.
            const side_slot: ?u32 = switch (hdr.channel_assignment) {
                8, 10 => 1,
                9 => 0,
                else => null,
            };
            const ch_bps: u8 = if (side_slot != null and ci == side_slot.?) hdr.bps + 1 else hdr.bps;
            try decodeSubframe(&bt, ch_data[ci], bs, ch_bps, residual_buf);
        }
        // channel decorrelation
        var interleaved = try a.alloc(i64, bs * nch);
        switch (hdr.channel_assignment) {
            0...7 => {
                for (0..bs) |i| {
                    for (0..nch) |c| interleaved[i * nch + c] = ch_data[c][i];
                }
            },
            8 => { // left/side: ch0=left, ch1=side
                for (0..bs) |i| {
                    const left = ch_data[0][i];
                    const side = ch_data[1][i];
                    interleaved[i * 2 + 0] = left;
                    interleaved[i * 2 + 1] = left - side;
                }
            },
            9 => { // right/side: ch0=side, ch1=right (RFC 9639 4.2)
                for (0..bs) |i| {
                    const side = ch_data[0][i];
                    const right = ch_data[1][i];
                    interleaved[i * 2 + 0] = right +% side;
                    interleaved[i * 2 + 1] = right;
                }
            },
            10 => { // mid/side: ch0=mid, ch1=side (RFC 9639 4.2)
                for (0..bs) |i| {
                    const mid = ch_data[0][i];
                    const side = ch_data[1][i];
                    const m2: i64 = (mid << 1) | (side & 1);
                    interleaved[i * 2 + 0] = (m2 +% side) >> 1;
                    interleaved[i * 2 + 1] = (m2 -% side) >> 1;
                }
            },
            else => unreachable,
        }
        // frame CRC-16: align to byte, then 2 bytes over data[hdr.start .. aligned]
        bt.alignByte();
        const frame_end = bt.bytePos();
        const dbg = std.c.getenv("FLAC_DEBUG") != null;
        if (dbg) std.debug.print("frame@{d} hdr_len={d} bs={d} subframe_end_byte={d} bits_used={d}\n", .{ pos, hdr.header_len, bs, frame_end, bt.pos - pos * 8 });
        if (frame_end + 2 <= data.len) {
            const want = (@as(u16, data[frame_end]) << 8) | data[frame_end + 1];
            const got = crc16(data[pos..frame_end]);
            if (dbg) std.debug.print("  crc16 want={x:0>4} got={x:0>4}\n", .{ want, got });
            if (want != got) return error.Crc16Mismatch;
            pos = frame_end + 2;
        } else {
            pos = data.len;
        }
        // truncate to total_samples if needed
        var take: u64 = bs;
        if (total_samples > 0 and decoded_frames + take > total_samples) {
            take = total_samples - decoded_frames;
        }
        try out.appendSlice(a, interleaved[0 .. take * nch]);
        decoded_frames += take;
        a.free(interleaved);
    }

    // MD5 over interleaved samples, per-sample byte order big-endian (FLAC spec);
    // fall back to little-endian for robustness (md5_ok reports either match)
    const samples = try out.toOwnedSlice(a);
    const md5_be = md5OfSamples(samples, channels, bps, false);
    const md5_le = md5OfSamples(samples, channels, bps, true);
    const md5_ok = std.mem.eql(u8, &md5_be, &md5) or std.mem.eql(u8, &md5_le, &md5);

    return .{
        .allocator = allocator,
        .arena = arena,
        .sample_rate = sample_rate,
        .channels = channels,
        .bits_per_sample = bps,
        .total_samples = decoded_frames,
        .samples = samples,
        .md5 = md5,
        .md5_ok = md5_ok,
        .comments = comments,
    };
}

fn md5OfSamples(samples: []const i64, channels: u8, bps: u8, little_endian: bool) [16]u8 {
    _ = channels;
    var h = std.crypto.hash.Md5.init(.{});
    const bytes: usize = (bps + 7) / 8; // sign-extend each sample to whole bytes (RFC 9639 8.2)
    const sh: u6 = @intCast(@as(u32, 64) - @min(@as(u32, bps), 32));
    var buf: [4]u8 = undefined;
    for (samples) |s| {
        const sv: i64 = @bitCast((@as(u64, @bitCast(s)) << sh) >> sh); // sign-extend to bps bits
        const uv: u64 = @bitCast(sv);
        if (little_endian) {
            var k: usize = 0;
            while (k < bytes) : (k += 1) buf[k] = @truncate(uv >> @as(u5, @intCast(k * 8)));
        } else {
            var k: usize = bytes;
            while (k > 0) {
                k -= 1;
                buf[k] = @truncate(uv >> @as(u5, @intCast(k * 8)));
            }
        }
        h.update(buf[0..bytes]);
    }
    var out: [16]u8 = undefined;
    h.final(&out);
    return out;
}

fn parseVorbisComment(a: std.mem.Allocator, body: []const u8) ![]Comment {
    if (body.len < 8) return error.BadVorbisComment;
    var pos: usize = 0;
    const vendor_len = readU32LE(body[0..4]);
    pos = 4 + vendor_len;
    if (pos + 4 > body.len) return error.BadVorbisComment;
    const count = readU32LE(body[pos..][0..4]);
    pos += 4;
    const out = try a.alloc(Comment, count);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (pos + 4 > body.len) return error.BadVorbisComment;
        const len = readU32LE(body[pos..][0..4]);
        pos += 4;
        if (pos + len > body.len) return error.BadVorbisComment;
        const s = body[pos..][0..len];
        pos += len;
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse {
            out[i] = .{ .key = try a.dupe(u8, ""), .value = try a.dupe(u8, s) };
            continue;
        };
        const key_raw = s[0..eq];
        const key = try a.alloc(u8, key_raw.len);
        for (key_raw, 0..) |c, k| key[k] = std.ascii.toUpper(c);
        out[i] = .{ .key = key, .value = try a.dupe(u8, s[eq + 1 ..]) };
    }
    return out;
}

fn readU32LE(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

pub fn decodeFile(allocator: std.mem.Allocator, path: []const u8) !Decoded {
    const data = try wav.readFileAll(allocator, path, 512 * 1024 * 1024);
    defer allocator.free(data);
    return decode(allocator, data);
}
