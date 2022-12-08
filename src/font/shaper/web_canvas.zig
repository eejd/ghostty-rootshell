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

    /// Shape the given text run. The text run must be the immediately previous
    /// text run that was iterated since the text run does share state with the
    /// Shaper struct.
    ///
    /// The return value is only valid until the next shape call is called.
    ///
    /// If there is not enough space in the cell buffer, an error is returned.
    pub fn shape(self: *Shaper, run: font.shape.TextRun) ![]font.shape.Cell {
        _ = self;
        _ = run;
        return error.Unimplemented;
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
            try self.shaper.run_buf.append(cp);
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

    export fn shaper_new(cap: usize) ?*Shaper {
        return shaper_new_(cap) catch null;
    }

    fn shaper_new_(cap: usize) !*Shaper {
        var cell_buf = try alloc.alloc(font.shape.Cell, cap);
        errdefer alloc.free(cell_buf);

        var shaper = try Shaper.init(alloc, cell_buf);
        errdefer shaper.deinit();

        var result = try alloc.create(Shaper);
        errdefer alloc.destroy(result);
        result.* = shaper;
        return result;
    }

    export fn shaper_free(ptr: ?*Shaper) void {
        if (ptr) |v| {
            alloc.free(v.cell_buf);
            v.deinit();
            alloc.destroy(v);
        }
    }

    /// Runs a test to verify shaping works properly.
    export fn shaper_test(
        self: *Shaper,
        group: *font.GroupCache,
        str: [*]const u8,
        len: usize,
    ) void {
        shaper_test_(self, group, str[0..len]) catch |err| {
            log.warn("error during shaper test err={}", .{err});
        };
    }

    fn shaper_test_(self: *Shaper, group: *font.GroupCache, str: []const u8) !void {
        // Create a terminal and print all our characters into it.
        var term = try terminal.Terminal.init(alloc, self.cell_buf.len, 80);
        defer term.deinit(alloc);
        for (str) |c| try term.print(c);

        // Iterate over the rows and print out all the runs we get.
        var rowIter = term.screen.rowIterator(.viewport);
        var y: usize = 0;
        while (rowIter.next()) |row| {
            defer y += 1;

            var iter = self.runIterator(group, row);
            while (try iter.next(alloc)) |run| {
                log.info("y={} run={}", .{ y, run });
            }
        }
    }
};
