//! Nocturne's bundled audio modules.
//!
//! These were vendored from the Cipher framework so Nocturne has no dependency
//! on a sibling checkout: FLAC decode, LRC parsing, M3U playlists, WAV I/O, a
//! crossfade/load helper, and a PulseAudio output path. The sink module in the
//! Cipher framework is the long-term output path; Nocturne keeps its own copy
//! here so it builds and ships standalone.
pub const wav = @import("audio/wav.zig");
pub const flac = @import("audio/flac.zig");
pub const lrc = @import("audio/lrc.zig");
pub const playlist = @import("audio/playlist.zig");
pub const pulse = @import("audio/pulse.zig");
pub const player = @import("audio/player.zig");