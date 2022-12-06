const std = @import("std");
const builtin = @import("builtin");
const wasm = @import("../wasm.zig");

// The function std.log will call.
pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // Build the string
    const level_txt = comptime level.asText();
    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    const txt = level_txt ++ prefix ++ format;
    const str = nosuspend std.fmt.allocPrint(wasm.alloc, txt, args) catch return;
    defer wasm.alloc.free(str);

    // Send it over to the JS side
    JS.log(str.ptr, str.len);
}

// We wrap our externs in this namespace so we can reuse symbols, otherwise
// "log" would collide.
const JS = struct {
    extern "env" fn log(ptr: [*]const u8, len: usize) void;
};
