const builtin = @import("builtin");

pub usingnamespace switch (builtin.zig_backend) {
    .stage1 => @cImport({
        @cInclude("uv.h");
    }),

    // Workaround for:
    // https://github.com/ziglang/zig/issues/12325
    else => @import("cimport.zig"),
};
