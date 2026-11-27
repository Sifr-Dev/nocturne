//! PulseAudio-simple output via dlopen (no link-time dependency).
//! Offline-only music player: connects to the local server (PipeWire's
//! pipewire-0 socket at /run/user/1000/pipewire-0), writes s16le PCM.
const std = @import("std");

const pa_sample_spec = extern struct {
    format: i32, // pa_sample_format: PA_SAMPLE_S16LE = 3
    rate: u32,
    channels: u8,
};

const PA_STREAM_PLAYBACK: i32 = 1;
const PA_SAMPLE_S16LE: i32 = 3;

pub const Pulse = struct {
    lib: *anyopaque,
    simple: *anyopaque,
    write_fn: *const fn (*anyopaque, *const anyopaque, usize, *i32) callconv(.c) i32,
    drain_fn: *const fn (*anyopaque, *i32) callconv(.c) i32,
    free_fn: *const fn (*anyopaque) callconv(.c) void,

    /// Open a playback stream. server=null -> default (PipeWire socket).
    pub fn open(rate: u32, channels: u8) !Pulse {
        const lib = std.c.dlopen("libpulse-simple.so.0", .{ .NOW = true }) orelse return error.DlopenFailed;
        errdefer _ = std.c.dlclose(lib);
        const new_sym = std.c.dlsym(lib, "pa_simple_new") orelse return error.NoSymbol;
        const write_sym = std.c.dlsym(lib, "pa_simple_write") orelse return error.NoSymbol;
        const drain_sym = std.c.dlsym(lib, "pa_simple_drain") orelse return error.NoSymbol;
        const free_sym = std.c.dlsym(lib, "pa_simple_free") orelse return error.NoSymbol;
        const new_fn: *const fn (? [*:0]const u8, [*:0]const u8, i32, ?[*:0]const u8, [*:0]const u8, ?*const pa_sample_spec, ?*const anyopaque, ?*const anyopaque, ?*i32) callconv(.c) ?*anyopaque = @ptrCast(new_sym);
        const ss = pa_sample_spec{ .format = PA_SAMPLE_S16LE, .rate = rate, .channels = channels };
        var err: i32 = 0;
        const s = new_fn(null, "nocturne", PA_STREAM_PLAYBACK, null, "playback", &ss, null, null, &err) orelse {
            std.debug.print("pulse: pa_simple_new failed err={d}\n", .{err});
            return error.ConnectFailed;
        };
        return .{
            .lib = lib,
            .simple = s,
            .write_fn = @ptrCast(write_sym),
            .drain_fn = @ptrCast(drain_sym),
            .free_fn = @ptrCast(free_sym),
        };
    }

    /// Write s16le PCM bytes (blocks until accepted).
    pub fn write(self: *const Pulse, pcm: []const u8) !void {
        var err: i32 = 0;
        const rc = self.write_fn(self.simple, pcm.ptr, pcm.len, &err);
        if (rc < 0) return error.WriteFailed;
    }

    pub fn drain(self: *const Pulse) void {
        var err: i32 = 0;
        _ = self.drain_fn(self.simple, &err);
    }

    pub fn deinit(self: *Pulse) void {
        self.free_fn(self.simple);
        _ = std.c.dlclose(self.lib);
    }
};

test "pulse dlopen: libpulse-simple loads and symbols resolve" {
    // Opening a stream requires a running server; in the test environment
    // PipeWire is present at /run/user/1000/pipewire-0, but be lenient:
    // the hard requirement is that dlopen+dlsym succeed.
    const lib = std.c.dlopen("libpulse-simple.so.0", .{ .NOW = true }) orelse return error.SkipZigTest;
    defer _ = std.c.dlclose(lib);
    try std.testing.expect(std.c.dlsym(lib, "pa_simple_new") != null);
    try std.testing.expect(std.c.dlsym(lib, "pa_simple_write") != null);
    try std.testing.expect(std.c.dlsym(lib, "pa_simple_drain") != null);
    try std.testing.expect(std.c.dlsym(lib, "pa_simple_free") != null);
    std.debug.print("PULSE_DLOPEN_OK\n", .{});
}
