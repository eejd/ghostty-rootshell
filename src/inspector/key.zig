const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../input.zig");
const CircBuf = @import("../circ_buf.zig").CircBuf;

/// Circular buffer of key events.
pub const EventRing = CircBuf(Event, undefined);

/// Represents a recorded keyboard event.
pub const Event = struct {
    /// The input event.
    event: input.KeyEvent,

    /// The binding that was triggered as a result of this event.
    binding: ?input.Binding.Action = null,

    /// The data sent to the pty as a result of this keyboard event.
    /// This is allocated using the inspector allocator.
    pty: []const u8 = "",

    /// State for the inspector GUI. Do not set this unless you're the inspector.
    imgui_state: struct {
        selected: bool = false,
    } = .{},

    pub fn init(alloc: Allocator, event: input.KeyEvent) !Event {
        var copy = event;
        copy.utf8 = "";
        if (event.utf8.len > 0) copy.utf8 = try alloc.dupe(u8, event.utf8);
        return .{ .event = copy };
    }

    pub fn deinit(self: *const Event, alloc: Allocator) void {
        if (self.event.utf8.len > 0) alloc.free(self.event.utf8);
        if (self.pty.len > 0) alloc.free(self.pty);
    }

    /// Returns a label that can be used for this event. This is null-terminated
    /// so it can be easily used with C APIs.
    pub fn label(self: *const Event, buf: []u8) ![:0]const u8 {
        var buf_stream = std.io.fixedBufferStream(buf);
        const writer = buf_stream.writer();

        switch (self.event.action) {
            .press => try writer.writeAll("Press: "),
            .release => try writer.writeAll("Release: "),
            .repeat => try writer.writeAll("Repeat: "),
        }

        if (self.event.mods.shift) try writer.writeAll("Shift+");
        if (self.event.mods.ctrl) try writer.writeAll("Ctrl+");
        if (self.event.mods.alt) try writer.writeAll("Alt+");
        if (self.event.mods.super) try writer.writeAll("Super+");
        try writer.writeAll(@tagName(self.event.key));

        // Null-terminator
        try writer.writeByte(0);
        return buf[0..(buf_stream.getWritten().len - 1) :0];
    }
};

test "event string" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var event = try Event.init(alloc, .{ .key = .a });
    defer event.deinit(alloc);

    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings("Press: a", try event.label(&buf));
}
