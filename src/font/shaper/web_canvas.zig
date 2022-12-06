const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");

const log = std.log.scoped(.font_shaper);

pub const Shaper = struct {
    /// The shared memory used for shaping results.
    cell_buf: []font.shape.Cell,

    /// The cell_buf argument is the buffer to use for storing shaped results.
    /// This should be at least the number of columns in the terminal.
    pub fn init(cell_buf: []font.shape.Cell) !Shaper {
        return Shaper{
            .cell_buf = cell_buf,
        };
    }

    pub fn deinit(self: *Shaper) void {
        _ = self;
    }
};

/// The wasm-compatible API.
pub const Wasm = struct {
    const wasm = @import("../../os/wasm.zig");
    const alloc = wasm.alloc;
};
