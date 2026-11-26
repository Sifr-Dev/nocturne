//! Offline bit-exactness harness: decode a FLAC with our decoder and with
//! ffmpeg (s32le), then compare every sample. Used for real-collection checks.
const std = @import("std");
const audio = @import("audio");

fn runCli(alloc: std.mem.Allocator, argv: []const []const u8) !u8 {
    const pid_rc = std.os.linux.fork();
    if (@as(i64, @bitCast(pid_rc)) < 0) return error.ForkFailed;
    if (pid_rc == 0) {
        const devnull = std.posix.openat(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch {
            std.os.linux.exit(127);
        };
        _ = std.os.linux.dup2(devnull, 1);
        _ = std.os.linux.dup2(devnull, 2);
        var args = try alloc.allocSentinel(?[*:0]const u8, argv.len, null);
        for (argv, 0..) |a, i| {
            const b = try alloc.allocSentinel(u8, a.len, 0);
            @memcpy(b, a);
            args[i] = b.ptr;
        }
        var envp = [_]?[*:0]const u8{ try zstr(alloc, "PATH=/usr/bin:/bin"), null };
        _ = std.os.linux.execve(args[0].?, @ptrCast(args.ptr), @ptrCast(envp[0..].ptr));
        _ = std.os.linux.exit(127);
    }
    var status: i32 = 0;
    while (true) {
        const wrc = std.os.linux.waitpid(@as(i32, @intCast(pid_rc)), &status, 0);
        if (@as(i64, @bitCast(wrc)) < 0) {
            if (std.os.linux.errno(wrc) == .INTR) continue;
            return error.WaitFailed;
        }
        break;
    }
    const st: u32 = @bitCast(status);
    if (std.os.linux.W.IFEXITED(st)) return std.os.linux.W.EXITSTATUS(st);
    return 255;
}

fn zstr(alloc: std.mem.Allocator, s: []const u8) ![*:0]u8 {
    const b = try alloc.allocSentinel(u8, s.len, 0);
    @memcpy(b, s);
    return b.ptr;
}

fn readU32LE(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

fn listFlacs(alloc: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
    const zdir = try alloc.allocSentinel(u8, dir_path.len, 0);
    defer alloc.free(zdir);
    @memcpy(zdir, dir_path);
    const fd_rc = std.os.linux.open(zdir.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (@as(i64, @bitCast(fd_rc)) < 0) return error.OpenDir;
    const fd: i32 = @intCast(fd_rc);
    defer _ = std.os.linux.close(fd);
    var files = std.ArrayList([]const u8).empty;
    errdefer files.deinit(alloc);
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
    return files.toOwnedSlice(alloc);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(alloc);
    for (init.args.vector) |a| try args.append(alloc, std.mem.span(a));
    if (args.items.len < 2) {
        std.debug.print("usage: flac-verify DIR [FILTER] [LIMIT]\n", .{});
        return;
    }
    const dir_path = args.items[1];
    const filter = if (args.items.len > 2) args.items[2] else "";
    const limit: usize = if (args.items.len > 3) (std.fmt.parseInt(usize, args.items[3], 10) catch 0) else 0;

    const files = try listFlacs(alloc, dir_path);
    defer {
        for (files) |f| alloc.free(f);
        alloc.free(files);
    }

    var checked: usize = 0;
    var exact: usize = 0;
    for (files) |path| {
        if (filter.len > 0 and std.mem.indexOf(u8, path, filter) == null) continue;
        if (limit > 0 and checked >= limit) break;
        checked += 1;
        var dec = audio.flac.decodeFile(alloc, path) catch |e| {
            std.debug.print("VERIFY_FAIL {s} err={s}\n", .{ std.fs.path.basename(path), @errorName(e) });
            continue;
        };
        defer dec.deinit();

        const raw_path = try std.fmt.allocPrint(alloc, "/tmp/verify-{d}.s32", .{std.os.linux.getpid()});
        defer alloc.free(raw_path);
        const raw_z = try alloc.allocSentinel(u8, raw_path.len, 0);
        defer alloc.free(raw_z);
        @memcpy(raw_z, raw_path);
        defer _ = std.c.unlink(raw_z);
        const rc = try runCli(alloc, &.{ "/usr/bin/ffmpeg", "-y", "-loglevel", "error", "-i", path, "-f", "s32le", "-c:a", "pcm_s32le", raw_path });
        if (rc != 0) {
            std.debug.print("VERIFY_FFMPEG_FAIL {s} rc={d}\n", .{ std.fs.path.basename(path), rc });
            continue;
        }
        const raw = try audio.wav.readFileAll(alloc, raw_path, 1 << 34);
        defer alloc.free(raw);

        const ref_n = raw.len / 4;
        if (ref_n != dec.samples.len) {
            std.debug.print("VERIFY_LEN_MISMATCH {s} ours={d} ref={d}\n", .{ std.fs.path.basename(path), dec.samples.len, ref_n });
            continue;
        }
        const shift: u6 = @intCast(32 - dec.bits_per_sample);
        var mismatches: usize = 0;
        var first_bad: usize = 0;
        for (dec.samples, 0..) |s, i| {
            const got: i32 = @intCast(s << shift);
            const want: i32 = @bitCast(readU32LE(raw[i * 4 ..][0..4]));
            if (got != want) {
                if (mismatches == 0) first_bad = i;
                mismatches += 1;
            }
        }
        const name = std.fs.path.basename(path);
        if (mismatches == 0) {
            exact += 1;
            std.debug.print("VERIFY_OK {s} samples={d} ch={d} bps={d} rate={d} md5_ok={}\n", .{ name, dec.samples.len, dec.channels, dec.bits_per_sample, dec.sample_rate, dec.md5_ok });
        } else {
            std.debug.print("VERIFY_MISMATCH {s} samples={d} ch={d} bps={d} mismatches={d} first_bad_idx={d}\n", .{ name, dec.samples.len, dec.channels, dec.bits_per_sample, mismatches, first_bad });
        }
    }
    std.debug.print("VERIFY_SUMMARY checked={d} exact={d}\n", .{ checked, exact });
}
