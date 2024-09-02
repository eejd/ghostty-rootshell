pub const c = @cImport({
    for (@import("defs.zig").cimport) |d| {
        @cDefine(d, "1");
    }
    @cInclude("wuffs-v0.4.c");
});
