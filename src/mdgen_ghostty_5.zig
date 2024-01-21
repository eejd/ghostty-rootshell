const std = @import("std");
const gen = @import("build/mdgen/mdgen.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const output = std.io.getStdOut().writer();
    try gen.substitute(alloc, @embedFile("build/mdgen/ghostty_5_header.md"), output);
    try gen.generate_config(output, false);
    try gen.substitute(alloc, @embedFile("build/mdgen/ghostty_5_footer.md"), output);
}
