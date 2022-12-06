const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const terminal = @import("../../terminal/main.zig");

const log = std.log.scoped(.font_shaper);

pub const Shaper = struct {
    const RunBuf = std.ArrayList(u32);

    /// The shared memory used for shaping results.
    cell_buf: []font.shape.Cell,

    /// The shared memory used for storing information about a run.
    run_buf: RunBuf,

    /// The cell_buf argument is the buffer to use for storing shaped results.
    /// This should be at least the number of columns in the terminal.
    pub fn init(alloc: Allocator, cell_buf: []font.shape.Cell) !Shaper {
        return Shaper{
            .cell_buf = cell_buf,
            .run_buf = try RunBuf.initCapacity(alloc, cell_buf.len),
        };
    }

    pub fn deinit(self: *Shaper) void {
        self.run_buf.deinit();
        self.* = undefined;
    }

    /// Returns an iterator that returns one text run at a time for the
    /// given terminal row. Note that text runs are are only valid one at a time
    /// for a Shaper struct since they share state.
    pub fn runIterator(
        self: *Shaper,
        group: *font.GroupCache,
        row: terminal.Screen.Row,
    ) font.shape.RunIterator {
        return .{ .hooks = .{ .shaper = self }, .group = group, .row = row };
    }

    /// The hooks for RunIterator.
    pub const RunIteratorHook = struct {
        shaper: *Shaper,

        pub fn prepare(self: RunIteratorHook) !void {
            // Reset the buffer for our current run
            self.shaper.run_buf.clearRetainingCapacity();
        }

        pub fn addCodepoint(self: RunIteratorHook, cp: u32, cluster: u32) !void {
            _ = cluster;
            try self.shaper.append(cp);
        }

        pub fn finalize(self: RunIteratorHook) !void {
            _ = self;
        }
    };
};

/// The wasm-compatible API.
pub const Wasm = struct {
    const wasm = @import("../../os/wasm.zig");
    const alloc = wasm.alloc;
};
