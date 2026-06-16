//! Kitty's drag and drop protocol (OSC 72)
//! Specification: https://sw.kovidgoyal.net/kitty/drag-and-drop-protocol/

const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const Terminator = @import("../../osc.zig").Terminator;

const log = std.log.scoped(.kitty_dnd_protocol);

pub const OSC = struct {
    /// The raw metadata that was received. Parse individual values with `readOption`.
    metadata: []const u8,
    /// The raw payload. Its meaning and encoding depend on the event type (`t` key).
    payload: ?[]const u8,
    /// The terminator used for this OSC, so any response can match it.
    terminator: Terminator,

    pub fn readOption(self: OSC, comptime key: Option) ?key.Type() {
        return key.read(self.metadata);
    }
};

/// Values for the `t` (event type) metadata key.
pub const EventType = enum {
    accept_drops,
    stop_accepting_drops,
    drop_move,
    drop_dropped,
    request_data,
    request_error,
    offer_drag,
    present_data,
    change_drag_image,
    drag_offer_event,
    drag_offer_error,
    uri_list_data,
    query,

    pub fn init(str: []const u8) ?EventType {
        if (str.len != 1) return null;
        return switch (str[0]) {
            'a' => .accept_drops,
            'A' => .stop_accepting_drops,
            'm' => .drop_move,
            'M' => .drop_dropped,
            'r' => .request_data,
            'R' => .request_error,
            'o' => .offer_drag,
            'p' => .present_data,
            'P' => .change_drag_image,
            'e' => .drag_offer_event,
            'E' => .drag_offer_error,
            'k' => .uri_list_data,
            'q' => .query,
            else => null,
        };
    }
};

/// Metadata keys defined by the protocol. Keys are case-sensitive: `x` and `X` are distinct.
pub const Option = enum {
    t,
    m,
    i,
    o,
    x,
    y,
    X,
    Y,

    pub fn Type(comptime key: Option) type {
        return switch (key) {
            .t => EventType,
            // The spec uses 32-bit signed or unsigned; we standardize on
            // i32 because the location keys legitimately take -1 (drag
            // leaves the window) and other keys never exceed i32 range.
            .m, .i, .o, .x, .y, .X, .Y => i32,
        };
    }

    pub fn read(comptime key: Option, metadata: []const u8) ?key.Type() {
        const name = @tagName(key);

        const value: []const u8 = value: {
            var pos: usize = 0;
            while (pos < metadata.len) {
                while (pos < metadata.len and std.ascii.isWhitespace(metadata[pos])) pos += 1;
                if (pos >= metadata.len) return null;

                // Case-sensitive match: x and X must not be confused.
                if (!std.mem.startsWith(u8, metadata[pos..], name)) {
                    pos = std.mem.indexOfScalarPos(u8, metadata, pos, ':') orelse return null;
                    pos += 1;
                    continue;
                }
                pos += name.len;

                while (pos < metadata.len and std.ascii.isWhitespace(metadata[pos])) pos += 1;
                if (pos >= metadata.len) return null;
                if (metadata[pos] != '=') return null;

                const end = std.mem.indexOfScalarPos(u8, metadata, pos, ':') orelse metadata.len;
                const start = pos + 1;
                break :value std.mem.trim(u8, metadata[start..end], &std.ascii.whitespace);
            }
            return null;
        };

        return switch (key) {
            .t => .init(value),
            .m, .i, .o, .x, .y, .X, .Y => std.fmt.parseInt(i32, value, 10) catch null,
        };
    }
};

test "OSC 72: metadata only, no payload" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=a";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqualStrings("t=a", cmd.kitty_dnd_protocol.metadata);
    try testing.expect(cmd.kitty_dnd_protocol.payload == null);
}

test "OSC 72: metadata and empty payload" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=a;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqualStrings("t=a", cmd.kitty_dnd_protocol.metadata);
    try testing.expectEqualStrings("", cmd.kitty_dnd_protocol.payload.?);
}

test "OSC 72: metadata and non-empty payload" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=a:i=5;text/plain text/uri-list";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqualStrings("t=a:i=5", cmd.kitty_dnd_protocol.metadata);
    try testing.expectEqualStrings("text/plain text/uri-list", cmd.kitty_dnd_protocol.payload.?);
}

test "OSC 72: readOption .t valid event types" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const cases = .{
        .{ "72;t=a", EventType.accept_drops },
        .{ "72;t=A", EventType.stop_accepting_drops },
        .{ "72;t=m", EventType.drop_move },
        .{ "72;t=M", EventType.drop_dropped },
        .{ "72;t=r", EventType.request_data },
        .{ "72;t=R", EventType.request_error },
        .{ "72;t=o", EventType.offer_drag },
        .{ "72;t=p", EventType.present_data },
        .{ "72;t=P", EventType.change_drag_image },
        .{ "72;t=e", EventType.drag_offer_event },
        .{ "72;t=E", EventType.drag_offer_error },
        .{ "72;t=k", EventType.uri_list_data },
        .{ "72;t=q", EventType.query },
    };

    inline for (cases) |case| {
        p.deinit();
        p = .init(testing.allocator);
        for (case[0]) |ch| p.next(ch);
        const cmd = p.end('\x1b').?.*;
        try testing.expect(cmd == .kitty_dnd_protocol);
        try testing.expectEqual(case[1], cmd.kitty_dnd_protocol.readOption(.t).?);
    }
}

test "OSC 72: readOption .t unknown value returns null" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=z";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.t) == null);
}

test "OSC 72: readOption integer keys" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=m:i=3:x=10:y=5:X=320:Y=200:o=1:m=0";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqual(@as(i32, 3), cmd.kitty_dnd_protocol.readOption(.i).?);
    try testing.expectEqual(@as(i32, 10), cmd.kitty_dnd_protocol.readOption(.x).?);
    try testing.expectEqual(@as(i32, 5), cmd.kitty_dnd_protocol.readOption(.y).?);
    try testing.expectEqual(@as(i32, 320), cmd.kitty_dnd_protocol.readOption(.X).?);
    try testing.expectEqual(@as(i32, 200), cmd.kitty_dnd_protocol.readOption(.Y).?);
    try testing.expectEqual(@as(i32, 1), cmd.kitty_dnd_protocol.readOption(.o).?);
    try testing.expectEqual(@as(i32, 0), cmd.kitty_dnd_protocol.readOption(.m).?);
}

test "OSC 72: readOption negative sentinel (-1 for drag leave)" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=m:x=-1:y=-1";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqual(@as(i32, -1), cmd.kitty_dnd_protocol.readOption(.x).?);
    try testing.expectEqual(@as(i32, -1), cmd.kitty_dnd_protocol.readOption(.y).?);
}

test "OSC 72: readOption case-sensitive key matching" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // x=10 must not be returned when asking for .X
    const input = "72;x=10:Y=200";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqual(@as(i32, 10), cmd.kitty_dnd_protocol.readOption(.x).?);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.X) == null);
    try testing.expectEqual(@as(i32, 200), cmd.kitty_dnd_protocol.readOption(.Y).?);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.y) == null);
}

test "OSC 72: readOption absent key returns null" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=a";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.i) == null);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.x) == null);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.X) == null);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.m) == null);
}

test "OSC 72: readOption malformed integer returns null" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;x=notanumber";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.x) == null);
}

test "OSC 72: BEL terminator recorded" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=q";
    for (input) |ch| p.next(ch);

    const cmd = p.end(0x07).?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expect(cmd.kitty_dnd_protocol.terminator == .bel);
}

pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*Command {
    assert(parser.state == .@"72");

    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };

    const data = cap.trailing();

    const metadata: []const u8, const payload: ?[]const u8 = result: {
        const sep = std.mem.indexOfScalar(u8, data, ';') orelse break :result .{ data, null };
        break :result .{ data[0..sep], data[sep + 1 .. data.len] };
    };

    parser.command = .{
        .kitty_dnd_protocol = .{
            .metadata = metadata,
            .payload = payload,
            .terminator = .init(terminator_ch),
        },
    };

    return &parser.command;
}
