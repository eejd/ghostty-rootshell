const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

pub export fn zig_fuzz_init() callconv(.c) void {}

pub export fn zig_fuzz_test(buf: [*]const u8, len: isize) callconv(.c) void {
    if (len <= 0) return;
    ghostty_fuzz_parser(buf, @intCast(len));
}

pub export fn ghostty_fuzz_parser(
    input_ptr: [*]const u8,
    input_len: usize,
) callconv(.c) void {
    var p: ghostty_vt.Parser = .init();
    defer p.deinit();
    for (input_ptr[0..input_len]) |byte| _ = p.next(byte);
}
