const std = @import("std");
const gen = @import("build/mdgen/mdgen.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const output = std.io.getStdOut().writer();
    try gen.substitute(alloc, @embedFile("build/mdgen/ghostty_5_header.md"), output);
    try gen.genConfig(output, false);
    try gen.genKeybindActions(output);
    try gen.substitute(alloc, @embedFile("build/mdgen/ghostty_5_footer.md"), output);
}
