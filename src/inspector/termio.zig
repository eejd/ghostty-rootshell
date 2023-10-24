const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const CircBuf = @import("../circ_buf.zig").CircBuf;
const Surface = @import("../Surface.zig");

/// The stream handler for our inspector.
pub const Stream = terminal.Stream(Handler);

/// VT event circular buffer.
pub const VTEventRing = CircBuf(VTEvent, undefined);

/// VT event
pub const VTEvent = struct {
    /// The formatted string of the event. This is allocated. We format the
    /// event for now because there is so much data to copy if we wanted to
    /// store the raw event.
    str: [:0]const u8,

    pub fn deinit(self: *VTEvent, alloc: Allocator) void {
        alloc.free(self.str);
    }
};

/// Our VT stream handler.
const Handler = struct {
    /// The surface that the inspector is attached to. We use this instead
    /// of the inspector because this is pointer-stable.
    surface: *Surface,

    /// This is called with every single terminal action.
    pub fn handleManually(self: *Handler, action: terminal.Parser.Action) !bool {
        const insp = self.surface.inspector orelse return false;
        const alloc = self.surface.alloc;
        const formatted = try std.fmt.allocPrintZ(alloc, "{}", .{action});
        errdefer alloc.free(formatted);

        const ev: VTEvent = .{
            .str = formatted,
        };

        const max_capacity = 100;
        insp.vt_events.append(ev) catch |err| switch (err) {
            error.OutOfMemory => if (insp.vt_events.capacity() < max_capacity) {
                // We're out of memory, but we can allocate to our capacity.
                const new_capacity = @min(insp.vt_events.capacity() * 2, max_capacity);
                try insp.vt_events.resize(insp.surface.alloc, new_capacity);
                try insp.vt_events.append(ev);
            } else {
                var it = insp.vt_events.iterator(.forward);
                if (it.next()) |old_ev| old_ev.deinit(insp.surface.alloc);
                insp.vt_events.deleteOldest(1);
                try insp.vt_events.append(ev);
            },

            else => return err,
        };

        return true;
    }
};
