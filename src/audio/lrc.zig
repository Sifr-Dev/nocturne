//! LRC synced-lyrics parser: [mm:ss.xx] (or [hh:mm:ss.xx]) tags, multiple tags
//! per line allowed, sorted by time. Metadata lines ([ti:...]) are skipped.
const std = @import("std");

pub const Line = struct {
    time_ms: u64,
    text: []const u8,
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ![]Line {
    var lines = std.ArrayList(Line).empty;
    errdefer {
        for (lines.items) |l| allocator.free(l.text);
        lines.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var pos: usize = 0;
        var tags = std.ArrayList(u64).empty;
        defer tags.deinit(allocator);
        while (pos < line.len and line[pos] == '[') {
            const close = std.mem.indexOfScalarPos(u8, line, pos + 1, ']') orelse break;
            const tag = line[pos + 1 .. close];
            if (parseTimeMs(tag)) |ms| {
                try tags.append(allocator, ms);
                pos = close + 1;
            } else break; // [ti:...] etc — not a timestamp
        }
        if (tags.items.len == 0) continue;
        const text_part = std.mem.trim(u8, line[pos..], " \t");
        for (tags.items) |ms| {
            try lines.append(allocator, .{ .time_ms = ms, .text = try allocator.dupe(u8, text_part) });
        }
    }
    const slice = try lines.toOwnedSlice(allocator);
    std.mem.sort(Line, slice, {}, struct {
        fn less(_: void, a: Line, b: Line) bool {
            return a.time_ms < b.time_ms;
        }
    }.less);
    return slice;
}

/// Index of the active lyric line at `ms` (last line with time_ms <= ms), or null.
pub fn lineAt(lines: []const Line, ms: u64) ?usize {
    var best: ?usize = null;
    for (lines, 0..) |l, i| {
        if (l.time_ms <= ms) best = i else break;
    }
    return best;
}

fn parseTimeMs(tag: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, tag, ':');
    var parts: [3][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |p| {
        if (n >= 3) return null;
        parts[n] = p;
        n += 1;
    }
    if (n < 2) return null;
    // optional .xxx fraction on the last component only
    var frac: u64 = 0;
    const last = parts[n - 1];
    const dot = std.mem.indexOfScalar(u8, last, '.');
    var last_int = last;
    if (dot) |d| {
        last_int = last[0..d];
        const fs = last[d + 1 ..];
        if (fs.len == 0) return null;
        var f3 = [_]u8{ '0', '0', '0' };
        const take = @min(3, fs.len);
        @memcpy(f3[0..take], fs[0..take]);
        frac = std.fmt.parseInt(u64, &f3, 10) catch return null;
    }
    var vals: [3]u64 = .{ 0, 0, 0 };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = if (i == n - 1) last_int else parts[i];
        vals[i] = std.fmt.parseInt(u64, p, 10) catch return null;
    }
    if (n == 2) return vals[0] * 60_000 + vals[1] * 1000 + frac; // mm:ss.xx
    return vals[0] * 3_600_000 + vals[1] * 60_000 + vals[2] * 1000 + frac; // hh:mm:ss.xx
}

test "lrc parse: tags, multiple per line, metadata skipped, sorted, lineAt" {
    const alloc = std.testing.allocator;
    const text =
        "[ti:Test Song]\n" ++
        "[ar:Tester]\n" ++
        "[00:01.00]first line\n" ++
        "[00:03.50][00:07.25]repeated line\n" ++
        "[01:02.75]last line\n";
    const lines = try parse(alloc, text);
    defer {
        for (lines) |l| alloc.free(l.text);
        alloc.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqual(@as(u64, 1000), lines[0].time_ms);
    try std.testing.expectEqualStrings("first line", lines[0].text);
    try std.testing.expectEqual(@as(u64, 3500), lines[1].time_ms);
    try std.testing.expectEqual(@as(u64, 7250), lines[2].time_ms);
    try std.testing.expectEqual(@as(u64, 62750), lines[3].time_ms);
    try std.testing.expectEqual(@as(?usize, null), lineAt(lines, 500));
    try std.testing.expectEqual(@as(?usize, 0), lineAt(lines, 1000));
    try std.testing.expectEqual(@as(?usize, 2), lineAt(lines, 8000));
    try std.testing.expectEqual(@as(?usize, 3), lineAt(lines, 999_999));
    std.debug.print("LRC_OK lines={d}\n", .{lines.len});
}
