//! nocturne — offline music player built on the Cipher framework.
//!
//!   nocturne [library-dir] [--render-wav OUT.wav]
//!
//! From-zero FLAC decoder (bit-exact vs flac/ffmpeg), synced lyrics
//! (LRC sidecar or embedded VORBIS LYRICS), M3U playlists, sample-exact
//! crossfade, PulseAudio-simple playback via dlopen (server: PipeWire).
//! The UI is framework-native: library list, now-playing, progress,
//! lyric pane with the active line highlighted, crossfade slider.
//! Offline-only by design: no network is ever touched.
const std = @import("std");
const cipher = @import("cipher");
const audio = @import("audio");

const runtime = cipher.runtime;
const input = cipher.input;

const LYRIC_COLOR = 0xFFE8ECF4;
const LYRIC_DIM = 0xFF8A93A6;
const LYRIC_HOT = 0xFF659EFF;

fn lockSpin(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

const TrackInfo = struct {
    path: []const u8,
    display: []const u8,
};

/// Scan a directory (non-recursive beyond depth 1) for .flac/.m3u entries.
fn scanLibrary(alloc: std.mem.Allocator, dir_path: []const u8) ![]TrackInfo {
    var out = std.ArrayList(TrackInfo).empty;
    const zdir = try alloc.allocSentinel(u8, dir_path.len, 0);
    defer alloc.free(zdir);
    @memcpy(zdir, dir_path);
    const fd_rc = std.os.linux.open(zdir.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (@as(i64, @bitCast(fd_rc)) < 0) return error.OpenDir;
    const fd: i32 = @intCast(fd_rc);
    defer _ = std.os.linux.close(fd);
    var buf: [8192]u8 align(8) = undefined; // kernel dirent64 records are 8-byte aligned
    while (true) {
        const n = std.os.linux.getdents64(fd, &buf, buf.len);
        if (@as(i64, @bitCast(n)) <= 0) break;
        var off: usize = 0;
        while (off < n) {
            var d: std.os.linux.dirent64 = undefined;
            @memcpy(std.mem.asBytes(&d), buf[off..][0..@sizeOf(std.os.linux.dirent64)]);
            const name_start = off + @offsetOf(std.os.linux.dirent64, "name"); // kernel: 19, not @sizeOf padding
            const name_end = off + d.reclen;
            const name_raw = buf[name_start..name_end];
            const end0 = std.mem.indexOfScalar(u8, name_raw, 0) orelse name_raw.len;
            const name = name_raw[0..end0];
            off += d.reclen;
            if (!std.mem.endsWith(u8, name, ".flac")) continue;
            const full = try std.fs.path.join(alloc, &.{ dir_path, name });
            const disp = try std.fmt.allocPrint(alloc, "{s}", .{name[0 .. name.len - 5]});
            try out.append(alloc, .{ .path = full, .display = disp });
        }
    }
    std.mem.sort(TrackInfo, out.items, {}, struct {
        fn less(_: void, a: TrackInfo, b: TrackInfo) bool {
            return std.mem.lessThan(u8, a.display, b.display);
        }
    }.less);
    return out.toOwnedSlice(alloc);
}

const Shared = struct {
    mutex: std.atomic.Mutex = .unlocked,
    playing: bool = true,
    volume: f32 = 0.8,
    cur_idx: usize = 0,
    /// position in interleaved s16 frames of the whole *mix* for the current pair
    frames_played: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// current track bytes (s16 interleaved), owned by app
    src: []const u8 = &.{},
    src_rate: u32 = 44100,
    src_channels: u8 = 2,
    /// s16 crossfade overlap in frames (0 = none)
    overlap_frames: u64 = 0,
    next_src: []const u8 = &.{},
    next_rate: u32 = 44100,
    next_channels: u8 = 2,
    ended: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn loadS16(alloc: std.mem.Allocator, path: []const u8) !struct { bytes: []u8, rate: u32, channels: u8, frames: u64, title: []const u8, artist: []const u8, lrc: []audio.lrc.Line } {
    var dec = try audio.flac.decodeFile(alloc, path);
    defer dec.deinit();
    const ch: u8 = dec.channels;
    const bytes = try alloc.alloc(u8, dec.samples.len * 2);
    const maxv: f64 = @floatFromInt((@as(i64, 1) << @intCast(dec.bits_per_sample - 1)) - 1);
    for (dec.samples, 0..) |s, i| {
        const c = @max(-maxv, @min(maxv, @as(f64, @floatFromInt(s))));
        const q: i16 = @intFromFloat(@round(c / maxv * 32767.0));
        bytes[i * 2] = @truncate(@as(u16, @bitCast(q)));
        bytes[i * 2 + 1] = @truncate(@as(u16, @bitCast(q)) >> 8);
    }
    // lyrics: prefer .lrc sidecar, fall back to embedded VORBIS LYRICS
    var lrc: []audio.lrc.Line = &.{};
    if (path.len > 5 and std.mem.endsWith(u8, path, ".flac")) {
        const sidecar = try std.fmt.allocPrint(alloc, "{s}.lrc", .{path[0 .. path.len - 5]});
        if (audio.wav.readFileAll(alloc, sidecar, 1 << 20)) |txt| {
            lrc = audio.lrc.parse(alloc, txt) catch &.{};
        } else |_| {}
    }
    if (lrc.len == 0) {
        if (dec.comment("LYRICS")) |lyr| {
            lrc = audio.lrc.parse(alloc, lyr) catch &.{};
        }
    }
    // dup title/artist out of the arena before it is released
    const title = alloc.dupe(u8, dec.comment("TITLE") orelse std.fs.path.basename(path)) catch return error.OutOfMemory;
    const artist = alloc.dupe(u8, dec.comment("ARTIST") orelse "unknown") catch return error.OutOfMemory;
    return .{ .bytes = bytes, .rate = dec.sample_rate, .channels = ch, .frames = dec.samples.len / ch, .title = title, .artist = artist, .lrc = lrc };
}

const LoadedTrack = struct {
    bytes: []u8,
    rate: u32,
    channels: u8,
    frames: u64,
    lrc: []audio.lrc.Line,
    title: []const u8,
    artist: []const u8,
};

pub const App = struct {
    alloc: std.mem.Allocator,
    tracks: []TrackInfo,
    shared: Shared = .{},
    cur_idx: usize = 0,
    cur: ?LoadedTrack = null,
    nxt: ?LoadedTrack = null,
    pos_bytes: u64 = 0, // guarded by shared.mutex (audio thread mutates)
    pulse_ok: bool = false,
    audio_started: bool = false,
    audio_thread: ?std.Thread = null,
    sel: i32 = 0,
    applied_sel: i32 = 0,
    crossfade_s: f32 = 2.0,
    now_playing: [256]u8 = undefined,
    now_playing_len: usize = 0,
    time_buf: [64]u8 = undefined,
    lyric_buf: [3][256]u8 = undefined,
    frames: u64 = 0,
    render_wav: ?[]const u8 = null,

    fn loadTrackIdx(self: *App, i: usize) ?LoadedTrack {
        const raw = loadS16(self.alloc, self.tracks[i].path) catch return null;
        return .{ .bytes = raw.bytes, .rate = raw.rate, .channels = raw.channels, .frames = raw.frames, .lrc = raw.lrc, .title = raw.title, .artist = raw.artist };
    }

    fn setNowPlaying(self: *App) void {
        if (self.cur) |c| {
            const s = std.fmt.bufPrint(&self.now_playing, "{s} — {s}", .{ c.title, c.artist }) catch "playing";
            self.now_playing_len = s.len;
        }
    }

    /// Immediately switch to track `idx` (called from UI thread).
    fn switchTo(self: *App, idx: usize) void {
        if (idx >= self.tracks.len) return;
        const loaded = self.loadTrackIdx(idx) orelse return;
        const ni = (idx + 1) % self.tracks.len;
        const nxt = self.loadTrackIdx(ni);
        lockSpin(&self.shared.mutex);
        self.cur_idx = idx;
        self.cur = loaded;
        self.pos_bytes = 0;
        self.shared.frames_played.store(0, .release);
        self.shared.src = loaded.bytes;
        self.shared.src_rate = loaded.rate;
        self.shared.src_channels = loaded.channels;
        self.nxt = nxt;
        self.shared.next_src = if (self.nxt) |n| n.bytes else &.{};
        self.shared.next_rate = if (self.nxt) |n| n.rate else loaded.rate;
        self.shared.next_channels = if (self.nxt) |n| n.channels else loaded.channels;
        self.shared.ended.store(false, .release);
        self.shared.playing = true;
        self.shared.overlap_frames = @intFromFloat(@max(0.0, self.crossfade_s) * @as(f32, @floatFromInt(loaded.rate)));
        self.shared.mutex.unlock();
        self.setNowPlaying();
        self.sel = @intCast(idx);
        self.applied_sel = self.sel;
        std.debug.print("NOCTURNE_TRACK idx={d} title=\"{s}\" frames={d} rate={d} ch={d}\n", .{ idx, loaded.title, loaded.frames, loaded.rate, loaded.channels });
    }

    fn posFrames(self: *App) u64 {
        return self.shared.frames_played.load(.acquire);
    }

    fn totalFrames(self: *App) u64 {
        if (self.cur) |c| return c.frames else return 0;
    }

    fn audioThreadMain(self: *App) void {
        var pulse: ?audio.pulse.Pulse = audio.pulse.Pulse.open(44100, 2) catch null;
        self.pulse_ok = pulse != null;
        if (pulse == null) std.debug.print("NOCTURNE_AUDIO_FALLBACK reason=pulse_open_failed\n", .{});
        const CHUNK_FRAMES: usize = 1024;
        var mixbuf: [CHUNK_FRAMES * 2 * 2]u8 = undefined; // s16 stereo chunk (max)
        while (!self.shared.quit.load(.acquire)) {
            lockSpin(&self.shared.mutex);
            if (!self.shared.playing or self.shared.src.len == 0) {
                self.shared.mutex.unlock();
                var ts = std.os.linux.timespec{ .sec = 0, .nsec = 5 * 1_000_000 };
                _ = std.os.linux.nanosleep(&ts, null);
                continue;
            }
            const ch: u64 = self.shared.src_channels;
            const bytes_per_frame: u64 = ch * 2;
            const cur_len_bytes: u64 = self.shared.src.len;
            const cur_frames: u64 = cur_len_bytes / bytes_per_frame;
            const pos_frames: u64 = self.pos_bytes / bytes_per_frame;
            var want_frames: u64 = CHUNK_FRAMES;
            if (pos_frames + want_frames > cur_frames) want_frames = cur_frames - pos_frames;
            // are we inside the crossfade overlap?
            const overlap = self.shared.overlap_frames;
            const overlap_start: u64 = cur_frames -| overlap;
            const chunk_in_overlap = overlap > 0 and pos_frames + want_frames > overlap_start and self.shared.next_src.len > 0;
            var i: u64 = 0;
            while (i < want_frames) : (i += 1) {
                const fi = pos_frames + i;
                const src_off: usize = @intCast(fi * bytes_per_frame);
                // per-frame: only blend once fi reaches the overlap start
                var g: f64 = 0.0;
                const fi_in_overlap = chunk_in_overlap and fi >= overlap_start;
                if (fi_in_overlap) {
                    const eff: u64 = fi - overlap_start;
                    g = @as(f64, @floatFromInt(eff + 1)) / @as(f64, @floatFromInt(overlap));
                    g = @min(1.0, @max(0.0, g));
                }
                var c: u64 = 0;
                while (c < ch) : (c += 1) {
                    const off: usize = src_off + @as(usize, @intCast(c)) * 2;
                    const cs: i16 = @bitCast(@as(u16, self.shared.src[off]) | (@as(u16, self.shared.src[off + 1]) << 8));
                    var s: f64 = @as(f64, @floatFromInt(cs));
                    if (fi_in_overlap and self.shared.next_src.len > 0) {
                        const n_bytes_per_frame: u64 = self.shared.next_channels * 2;
                        const rel: u64 = fi - (cur_frames -| overlap); // frame index into next
                        if (self.shared.next_src.len >= (rel + 1) * n_bytes_per_frame) {
                            const noff: usize = @intCast(rel * n_bytes_per_frame + c * 2);
                            if (noff + 1 < self.shared.next_src.len) {
                                const ns: i16 = @bitCast(@as(u16, self.shared.next_src[noff]) | (@as(u16, self.shared.next_src[noff + 1]) << 8));
                                s = s * (1.0 - g) + @as(f64, @floatFromInt(ns)) * g;
                            }
                        }
                    }
                    s *= @as(f64, @floatFromInt(@as(i64, @intFromFloat(self.shared.volume * 100)))) / 100.0;
                    const q: i16 = @intFromFloat(@max(-32768.0, @min(32767.0, s)));
                    const o: usize = @intCast((i * ch + c) * 2);
                    mixbuf[o] = @truncate(@as(u16, @bitCast(q)));
                    mixbuf[o + 1] = @truncate(@as(u16, @bitCast(q)) >> 8);
                }
            }
            const out_bytes: usize = @intCast(want_frames * bytes_per_frame);
            if (pulse) |p| {
                p.write(mixbuf[0..out_bytes]) catch {};
            }
            self.shared.frames_played.store(pos_frames + want_frames, .release);
            self.pos_bytes += want_frames * bytes_per_frame;
            if (pos_frames + want_frames >= cur_frames) {
                // track finished: promote next, or end
                if (self.nxt != null and self.shared.next_src.len > 0) {
                    self.cur = self.nxt;
                    self.nxt = null;
                    self.cur_idx = (self.cur_idx + 1) % self.tracks.len;
                    const c = self.cur.?;
                    self.shared.src = c.bytes;
                    self.shared.src_rate = c.rate;
                    self.shared.src_channels = c.channels;
                    self.shared.frames_played.store(0, .release);
                    self.pos_bytes = 0;
                    // preload the following track
                    const ni = (self.cur_idx + 1) % self.tracks.len;
                    self.nxt = self.loadTrackIdx(ni);
                    self.shared.next_src = if (self.nxt) |n| n.bytes else &.{};
                    self.shared.next_rate = if (self.nxt) |n| n.rate else c.rate;
                    self.shared.next_channels = if (self.nxt) |n| n.channels else c.channels;
                    self.shared.overlap_frames = @intFromFloat(@max(0.0, self.crossfade_s) * @as(f32, @floatFromInt(c.rate)));
                    self.setNowPlaying();
                    std.debug.print("NOCTURNE_TRACK_AUTO idx={d} title=\"{s}\"\n", .{ self.cur_idx, c.title });
                } else {
                    self.shared.playing = false;
                    self.shared.ended.store(true, .release);
                    std.debug.print("NOCTURNE_ENDED\n", .{});
                }
            }
            self.shared.mutex.unlock();
            var ts = std.os.linux.timespec{ .sec = 0, .nsec = 1 * 1_000_000 };
            _ = std.os.linux.nanosleep(&ts, null);
        }
        if (pulse) |*p| {
            p.drain();
            p.deinit();
        }
    }

    pub fn onEvent(self: *App, rt: *runtime.Runtime, ev: input.Event) void {
        switch (ev) {
            .key => |k| {
                if (!k.pressed) return;
                switch (k.key) {
                    .esc => rt.requestQuit(),
                    .space => {
                        lockSpin(&self.shared.mutex);
                        if (self.shared.ended.load(.acquire)) {
                            self.shared.ended.store(false, .release);
                            self.pos_bytes = 0;
                            self.shared.frames_played.store(0, .release);
                        }
                        self.shared.playing = !self.shared.playing;
                        self.shared.mutex.unlock();
                        std.debug.print("NOCTURNE_PLAYING playing={}\n", .{self.shared.playing});
                    },
                    .printable => {
                        if (k.char) |c| {
                            switch (c) {
                                'n' => self.switchTo((self.cur_idx + 1) % self.tracks.len),
                                'p' => self.switchTo((self.cur_idx + self.tracks.len - 1) % self.tracks.len),
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            },
            .close => rt.requestQuit(),
            else => {},
        }
    }

    pub fn onFrame(self: *App, rt: *runtime.Runtime) !void {
        const u = rt.ui() orelse return;
        if (!self.audio_started) {
            self.audio_started = true;
            self.audio_thread = try std.Thread.spawn(.{}, App.audioThreadMain, .{self});
        }
        // apply library selection as track change
        if (self.sel != self.applied_sel) self.switchTo(@intCast(@max(0, self.sel)));
        self.frames += 1;
        const root = u.current();
        root.dir = .row;

        // ---- library column ----
        try u.panel(.{ .fixed = 400 }, .{ .grow = 1.0 }, 14, 6);
        try u.label("nocturne — offline library", cipher.ui.COLOR_TEXT);
        var items: [512][]const u8 = undefined;
        const n_items = @min(self.tracks.len, 512);
        for (self.tracks[0..n_items], 0..) |t, i| items[i] = t.display;
        try cipher.widgets.listView(u, 372, 24, items[0..n_items], &self.sel);
        u.endPanel();

        // ---- now playing column ----
        try u.panel(.{ .grow = 1.0 }, .{ .grow = 1.0 }, 24, 12);
        try u.label(if (self.now_playing_len > 0) self.now_playing[0..self.now_playing_len] else "nothing playing", LYRIC_COLOR);
        var lbuf: [96]u8 = undefined;
        const total_s: f64 = @as(f64, @floatFromInt(self.totalFrames())) / @as(f64, @floatFromInt(if (self.cur) |c| c.rate else 44100));
        const cur_s: f64 = @as(f64, @floatFromInt(self.posFrames())) / @as(f64, @floatFromInt(if (self.cur) |c| c.rate else 44100));
        const ts = std.fmt.bufPrint(&lbuf, "{d:02.0}:{d:02.0} / {d:02.0}:{d:02.0}   track {d}/{d}", .{ @floor(cur_s) / 60, @mod(@floor(cur_s), 60), @floor(total_s) / 60, @mod(@floor(total_s), 60), self.cur_idx + 1, self.tracks.len }) catch "";
        try u.label(ts, cipher.ui.COLOR_TEXT_DIM);
        const frac: f32 = if (self.totalFrames() > 0) @as(f32, @floatFromInt(self.posFrames())) / @as(f32, @floatFromInt(self.totalFrames())) else 0;
        try cipher.widgets.progress(u, 560, frac);

        // transport buttons
        const prev_w = try u.button("prev");
        const pause_w = try u.button(if (self.shared.playing) "pause" else "play");
        const next_w = try u.button("next");
        if (prev_w) self.switchTo((self.cur_idx + self.tracks.len - 1) % self.tracks.len);
        if (next_w) self.switchTo((self.cur_idx + 1) % self.tracks.len);
        if (pause_w) {
            lockSpin(&self.shared.mutex);
            self.shared.playing = !self.shared.playing;
            self.shared.mutex.unlock();
        }
        try u.label("volume", cipher.ui.COLOR_TEXT_DIM);
        var vol_slider: f32 = self.shared.volume * 10.0;
        try cipher.widgets.slider(u, 560, 0, 10, &vol_slider);
        self.shared.volume = vol_slider / 10.0;
        var vbuf: [32]u8 = undefined;
        const vs = std.fmt.bufPrint(&vbuf, "{d:.0}%", .{self.shared.volume * 100.0}) catch "";
        try u.label(vs, cipher.ui.COLOR_TEXT_DIM);
        // context menu (declared after everything else so it paints on top)
        const menu_anchor = cipher.layout.Rect{ .x = 0, .y = 0, .w = @floatFromInt(rt.width), .h = @floatFromInt(rt.height) };
        const menu_items = [_]cipher.widgets.MenuItem{
            .{ .label = if (self.shared.playing) "pause" else "play" },
            .{ .label = "next track" },
            .{ .label = "previous track" },
        };
        if (try cipher.widgets.contextMenu(u, menu_anchor, &menu_items)) |choice| {
            switch (choice) {
                0 => {
                    lockSpin(&self.shared.mutex);
                    self.shared.playing = !self.shared.playing;
                    self.shared.mutex.unlock();
                },
                1 => self.switchTo((self.cur_idx + 1) % self.tracks.len),
                2 => self.switchTo((self.cur_idx + self.tracks.len - 1) % self.tracks.len),
                else => {},
            }
        }
        try u.label("crossfade", cipher.ui.COLOR_TEXT_DIM);
        try cipher.widgets.slider(u, 560, 0, 10, &self.crossfade_s);
        var cbuf: [32]u8 = undefined;
        const cs = std.fmt.bufPrint(&cbuf, "{d:.1}s", .{self.crossfade_s}) catch "";
        try u.label(cs, cipher.ui.COLOR_TEXT_DIM);

        // ---- synced lyrics ----
        try u.spacer(8);
        if (self.cur) |c| {
            if (c.lrc.len > 0) {
                const ms: u64 = @intFromFloat(cur_s * 1000.0);
                const active = audio.lrc.lineAt(c.lrc, ms);
                const lo: i64 = if (active) |a| @as(i64, @intCast(a)) - 1 else 0;
                var li: i64 = lo;
                while (li <= lo + 2) : (li += 1) {
                    if (li < 0 or li >= c.lrc.len) continue;
                    const line = c.lrc[@intCast(li)];
                    const hot = if (active) |a| @as(i64, @intCast(a)) == li else false;
                    const text = if (line.text.len > 100) line.text[0..100] else line.text;
                    try u.label(text, if (hot) LYRIC_HOT else LYRIC_DIM);
                }
            } else {
                try u.label("(no synced lyrics — embed VORBIS LYRICS or ship a .lrc)", LYRIC_DIM);
            }
        }
        u.endPanel();
    }
};

fn offlineRender(alloc: std.mem.Allocator, tracks: []TrackInfo, out_path: []const u8) !void {
    if (tracks.len == 0) return error.NoTracks;
    var acc = try audio.player.loadTrack(alloc, tracks[0].path);
    defer acc.deinit();
    const ch = acc.channels;
    const overlap_frames: usize = @intFromFloat(2.0 * @as(f64, @floatFromInt(acc.sample_rate)));
    var mixed: []f64 = try alloc.dupe(f64, acc.samples);
    for (tracks[1..]) |t| {
        var trk = try audio.player.loadTrack(alloc, t.path);
        defer trk.deinit();
        if (trk.channels != ch) return error.ChannelMismatch;
        const newmix = try audio.player.crossfade(alloc, mixed, trk.samples, overlap_frames, ch);
        alloc.free(mixed);
        mixed = newmix;
    }
    // quantize to i16-scale raw ints and write a 16-bit WAV
    const maxv: f64 = 32767.0;
    const tmp = try alloc.alloc(i64, mixed.len);
    defer alloc.free(tmp);
    for (mixed, 0..) |s, i| tmp[i] = @as(i64, @intFromFloat(@round(@max(-maxv, @min(maxv, s)) / maxv * 32767.0)));
    alloc.free(mixed);
    try audio.wav.write(alloc, out_path, acc.sample_rate, ch, 16, tmp);
    std.debug.print("NOCTURNE_RENDER_OK tracks={d} samples={d} rate={d} out={s}\n", .{ tracks.len, tmp.len, acc.sample_rate, out_path });
}

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(alloc);
    for (init.args.vector) |a| try args.append(alloc, std.mem.span(a));

    var lib_dir: []const u8 = "/tmp/opencode/nocturne-lib";
    var render_out: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        if (std.mem.eql(u8, args.items[i], "--render-wav") and i + 1 < args.items.len) {
            render_out = args.items[i + 1];
            i += 1;
        } else if (args.items[i].len > 0 and args.items[i][0] != '-') {
            lib_dir = args.items[i];
        }
    }

    var tracks: []TrackInfo = undefined;
    const is_playlist = std.mem.endsWith(u8, lib_dir, ".m3u") or std.mem.endsWith(u8, lib_dir, ".m3u8");
    if (is_playlist) {
        const text = audio.wav.readFileAll(alloc, lib_dir, 1 << 20) catch |e| {
            std.debug.print("NOCTURNE_PLAYLIST_ERROR path={s} err={s}\n", .{ lib_dir, @errorName(e) });
            return e;
        };
        const base = std.fs.path.dirname(lib_dir) orelse ".";
        const entries = audio.playlist.parse(alloc, text, base) catch |e| {
            std.debug.print("NOCTURNE_PLAYLIST_ERROR path={s} err={s}\n", .{ lib_dir, @errorName(e) });
            return e;
        };
        const out = try alloc.alloc(TrackInfo, entries.len);
        for (entries, 0..) |e, j| {
            out[j] = .{
                .path = e.path,
                .display = e.title orelse std.fs.path.basename(e.path),
            };
        }
        tracks = out;
        std.debug.print("NOCTURNE_PLAYLIST path={s} entries={d}\n", .{ lib_dir, tracks.len });
    } else {
        tracks = scanLibrary(alloc, lib_dir) catch |e| {
            std.debug.print("NOCTURNE_LIB_ERROR dir={s} err={s}\n", .{ lib_dir, @errorName(e) });
            return e;
        };
        std.debug.print("NOCTURNE_LIB dir={s} tracks={d}\n", .{ lib_dir, tracks.len });
    }
    if (tracks.len == 0) {
        std.debug.print("NOCTURNE_EMPTY dir={s}\n", .{lib_dir});
        return;
    }

    if (render_out) |out| {
        try offlineRender(alloc, tracks, out);
        return;
    }

    var app = App{ .alloc = alloc, .tracks = tracks };
    // preload track 0 before the window comes up so first paint has content
    app.switchTo(0);
    try runtime.runWith(App, &app, .{
        .title = "nocturne",
        .app_id = "nocturne",
        // Best-effort fallbacks (silently skipped if the font is absent).
        .fallback_font_paths = &.{ "/usr/share/fonts/TTF/DejaVuSans.ttf", "/usr/share/fonts/TTF/DejaVuMathTeXGyre.ttf" },
        .ui_px = 15,
        .width = 1280,
        .height = 760,
    });
    if (app.audio_started) {
        app.shared.quit.store(true, .release);
        app.audio_thread.?.join();
    }
    std.debug.print("NOCTURNE_EXIT frames={d} rss_kb={d}\n", .{ app.frames, blk: {
        const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/status", .{ .ACCMODE = .RDONLY }, 0) catch break :blk 0;
        defer _ = std.c.close(fd);
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(fd, buf[0..]) catch break :blk 0;
        const s = buf[0..n];
        const idx = std.mem.indexOf(u8, s, "VmRSS:") orelse break :blk 0;
        const rest = s[idx + 6 ..];
        var j: usize = 0;
        while (j < rest.len and (rest[j] == ' ' or rest[j] == '\t')) : (j += 1) {}
        const start = j;
        while (j < rest.len and rest[j] >= '0' and rest[j] <= '9') : (j += 1) {}
        break :blk std.fmt.parseInt(u64, rest[start..j], 10) catch 0;
    } });
}
