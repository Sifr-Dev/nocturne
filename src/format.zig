//! Single module root for Nocturne's audio format stack.
//!
//! `resampler` and `output_format` import each other by relative path, so they
//! must live in one module; this facade exposes both to the application and the
//! tests without duplicating the file into two modules.
pub const resampler = @import("resampler.zig");
pub const output_format = @import("output_format.zig");

test {
    _ = resampler;
    _ = output_format;
}
