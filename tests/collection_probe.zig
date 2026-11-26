//! Diagnostic sweep: decode every FLAC in a collection directory and report
//! decoder errors / MD5 status. Not part of the default test set.
const std = @import("std");
const flac = @import("audio").flac;

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;
    var dir_path: []const u8 = "/home/sifr/Music";
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(alloc);
    for (init.args.vector) |a| try args.append(alloc, std.mem.span(a));
    if (args.items.len > 1) dir_path = args.items[1];

    const zdir = try alloc.allocSentinel(u8, dir_path.len, 0);
    defer alloc.free(zdir);
    @memcpy(zdir, dir_path);
    const fd_rc = std.os.linux.open(zdir.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (@as(i64, @bitCast(fd_rc)) < 0) return error.OpenDir;
    const fd: i32 = @intCast(fd_rc);
    defer _ = std.os.linux.close(fd);

    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(alloc);
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = std.os.linux.getdents64(fd, &buf, buf.len);
        if (@as(i64, @bitCast(n)) <= 0) break;
        var off: usize = 0;
        while (off < n) {
            var d: std.os.linux.dirent64 = undefined;
            @memcpy(std.mem.asBytes(&d), buf[off..][0..@sizeOf(std.os.linux.dirent64)]);
            const name_start = off + @offsetOf(std.os.linux.dirent64, "name");
            const name_end = off + d.reclen;
            const name_raw = buf[name_start..name_end];
            const end0 = std.mem.indexOfScalar(u8, name_raw, 0) orelse name_raw.len;
            const name = name_raw[0..end0];
            off += d.reclen;
            if (!std.mem.endsWith(u8, name, ".flac")) continue;
            try files.append(alloc, try std.fs.path.join(alloc, &.{ dir_path, name }));
        }
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);

    var ok: usize = 0;
    var failed: usize = 0;
    var md5_bad: usize = 0;
    var md5_unset: usize = 0;
    for (files.items) |path| {
        var dec = flac.decodeFile(alloc, path) catch |e| {
            failed += 1;
            std.debug.print("FAIL {s} err={s}\n", .{ std.fs.path.basename(path), @errorName(e) });
            continue;
        };
        defer dec.deinit();
        if (dec.md5_ok) {
            ok += 1;
        } else if (std.mem.allEqual(u8, &dec.md5, 0)) {
            md5_unset += 1; // no signature embedded: integrity is checked by Crc16 per frame
        } else {
            md5_bad += 1;
            std.debug.print("MD5  {s} samples={d} ch={d} bps={d} rate={d}\n", .{ std.fs.path.basename(path), dec.samples.len, dec.channels, dec.bits_per_sample, dec.sample_rate });
        }
    }
    std.debug.print("COLLECTION_SUMMARY files={d} ok={d} failed={d} md5_bad={d} md5_unset={d}\n", .{ files.items.len, ok, failed, md5_bad, md5_unset });
}
