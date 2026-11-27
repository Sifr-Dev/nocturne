//! M3U / M3U8 playlist parser (#EXTM3U, #EXTINF:<sec>,<title>), relative
//! paths resolved against the playlist's directory.
const std = @import("std");

pub const Entry = struct {
    path: []const u8, // absolute or base-resolved
    title: ?[]const u8,
    length_sec: ?f64,
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8, base_dir: []const u8) ![]Entry {
    var out = std.ArrayList(Entry).empty;
    errdefer {
        for (out.items) |e| {
            allocator.free(e.path);
            if (e.title) |t| allocator.free(t);
        }
        out.deinit(allocator);
    }
    var pending_len: ?f64 = null;
    var pending_title: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') {
            if (std.mem.startsWith(u8, line, "#EXTINF:")) {
                const rest = line["#EXTINF:".len..];
                const comma = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
                pending_len = std.fmt.parseFloat(f64, rest[0..comma]) catch null;
                pending_title = try allocator.dupe(u8, rest[comma + 1 ..]);
            }
            continue;
        }
        // a path line
        var path: []const u8 = undefined;
        if (std.fs.path.isAbsolute(line) or std.mem.indexOf(u8, line, "://") != null) {
            path = try allocator.dupe(u8, line);
        } else {
            path = try std.fs.path.join(allocator, &.{ base_dir, line });
        }
        try out.append(allocator, .{ .path = path, .title = pending_title, .length_sec = pending_len });
        pending_title = null;
        pending_len = null;
    }
    return out.toOwnedSlice(allocator);
}

test "m3u parse: extinf, relative resolution, comments" {
    const alloc = std.testing.allocator;
    const text = "#EXTM3U\n#EXTINF:180,Song One\nsong1.flac\n#EXTINF:200,Song Two\nsub/song2.flac\n#EXTINF:-1,Stream\nhttp://x/y.flac\nplain.flac\n";
    const entries = try parse(alloc, text, "/music");
    defer {
        for (entries) |e| {
            alloc.free(e.path);
            if (e.title) |t| alloc.free(t);
        }
        alloc.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqualStrings("/music/song1.flac", entries[0].path);
    try std.testing.expectEqualStrings("Song One", entries[0].title.?);
    try std.testing.expectApproxEqAbs(@as(f64, 180), entries[0].length_sec.?, 1e-9);
    try std.testing.expectEqualStrings("/music/sub/song2.flac", entries[1].path);
    try std.testing.expectEqualStrings("http://x/y.flac", entries[2].path);
    try std.testing.expect(entries[3].title == null);
    std.debug.print("M3U_OK entries={d}\n", .{entries.len});
}
