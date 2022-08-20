pub const c = @import("c.zig");

/// Given a codepoint, return a character width analogous to `wcwidth(codepoint)`,
/// except that a width of 0 is returned for non-printable codepoints
/// instead of -1 as in `wcwidth`.
pub fn charwidth(codepoint: u21) u8 {
    return @intCast(u8, c.utf8proc_charwidth(@intCast(i32, codepoint)));
}
