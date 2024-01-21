const std = @import("std");
const gen = @import("generate_markdown.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const output = std.io.getStdOut().writer();

    try gen.substitute(alloc, @embedFile("doc/ghostty_5_header.md"), output);

    try gen.generate_config(output, false);

    try gen.substitute(alloc, @embedFile("doc/ghostty_5_footer.md"), output);
}
