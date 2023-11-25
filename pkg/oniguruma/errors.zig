const c = @import("c.zig");

/// Maximum error message length.
pub const MAX_ERROR_LEN = c.ONIG_MAX_ERROR_MESSAGE_LEN;

/// Convert an Oniguruma error to an error.
pub fn convertError(code: c_int) !void {
    switch (code) {
        c.ONIG_NORMAL => {},
        else => return error.OnigurumaError,
    }
}

/// Convert an error code to a string. buf must be at least
/// MAX_ERROR_LEN bytes long.
pub fn errorString(buf: []u8, code: c_int) ![]u8 {
    const len = c.onig_error_code_to_str(buf.ptr, code);
    return buf[0..@intCast(len)];
}
