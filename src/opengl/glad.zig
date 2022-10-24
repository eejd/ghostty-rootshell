const std = @import("std");
const c = @import("c.zig");

pub const Context = c.GladGLContext;

/// This is the current context. Set this var manually prior to calling
/// any of this package's functions. I know its nasty to have a global but
/// this makes it match OpenGL API styles where it also operates on a
/// threadlocal global.
pub threadlocal var context: Context = undefined;

/// Initialize Glad. This is guaranteed to succeed if no errors are returned.
/// The getProcAddress param is an anytype so that we can accept multiple
/// forms of the function depending on what we're interfacing with.
pub fn load(getProcAddress: anytype) !c_int {
    const GlProc = std.meta.FnPtr(fn () callconv(.C) void);
    const GlfwFn = std.meta.FnPtr(fn ([*:0]const u8) callconv(.C) ?GlProc);

    const res = switch (@TypeOf(getProcAddress)) {
        // glfw
        GlfwFn => c.gladLoadGLContext(&context, @ptrCast(
            std.meta.FnPtr(fn ([*c]const u8) callconv(.C) ?GlProc),
            getProcAddress,
        )),

        // try as-is. If this introduces a compiler error, then add a new case.
        else => c.gladLoadGLContext(&context, getProcAddress),
    };
    if (res == 0) return error.GLInitFailed;
    return res;
}

pub fn unload() void {
    c.gladLoaderUnloadGLContext(&context);
    context = undefined;
}

pub fn versionMajor(res: c_int) c_uint {
    // https://github.com/ziglang/zig/issues/13162
    // return c.GLAD_VERSION_MAJOR(res);
    return @intCast(c_uint, @divTrunc(res, 10000));
}

pub fn versionMinor(res: c_int) c_uint {
    // https://github.com/ziglang/zig/issues/13162
    // return c.GLAD_VERSION_MINOR(res);
    return @intCast(c_uint, @mod(res, 10000));
}
