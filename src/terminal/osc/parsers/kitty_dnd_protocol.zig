//! Kitty's drag and drop protocol (OSC 72)
//! Specification: https://sw.kovidgoyal.net/kitty/drag-and-drop-protocol/
//!
//! The OSC 72 escape has the form:
//!
//!     OSC 72 ; metadata ; payload ST
//!
//! Where `metadata` is a colon separated list of `key=value` pairs and
//! `payload` is event-type specific (a space separated MIME list, base64
//! encoded binary data, or absent). The protocol is chunked at 4096 bytes
//! per payload; chunked transfers are signalled via the `m` metadata key.
//!
//! This file only parses individual OSC 72 events. Reassembly of chunked
//! transfers and event semantics (drag state machine, file I/O for the
//! remote machine subprotocols, etc.) are responsibilities of the
//! action/dispatch layer above.

const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const Terminator = @import("../../osc.zig").Terminator;

const log = std.log.scoped(.kitty_dnd_protocol);

pub const OSC = struct {
    /// The raw metadata that was received. Parse individual values with
    /// the `readOption` method.
    metadata: []const u8,
    /// The raw payload. Its meaning depends on the event type (`t` key)
    /// and may be base64 encoded.
    payload: ?[]const u8,
    /// The terminator used for the inbound OSC, recorded so that any
    /// response we emit can match it.
    terminator: Terminator,

    pub fn readOption(self: OSC, comptime key: Option) ?key.Type() {
        return key.read(self.metadata);
    }
};

/// The set of values the `t` (event type) key may take. Each variant maps
/// to a single ASCII character per the spec.
pub const EventType = enum {
    /// `t=a` — client begins accepting drops, payload is space-separated MIME list.
    accept_drops,
    /// `t=A` — client no longer wishes to accept drops.
    stop_accepting_drops,
    /// `t=m` — drop move event (terminal → client).
    drop_move,
    /// `t=M` — drop committed event (terminal → client).
    drop_dropped,
    /// `t=r` — request data (or response data, or end-of-drop sentinel).
    request_data,
    /// `t=R` — error response for a data request.
    request_error,
    /// `t=o` — start offering drags / drag-start gesture.
    offer_drag,
    /// `t=p` — pre-send data for an offered MIME type or drag image.
    present_data,
    /// `t=P` — change drag image or finalize start-drag.
    change_drag_image,
    /// `t=e` — drag offer status event (terminal → client).
    drag_offer_event,
    /// `t=E` — drag offer error or cancel.
    drag_offer_error,
    /// `t=k` — data for entries in the offered text/uri-list (drag-out).
    uri_list_data,
    /// `t=q` — query protocol support.
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

/// All metadata keys defined by the protocol. Keys are case-sensitive —
/// `x` and `X` (and `y`/`Y`, `m`/no `M` key but `M` is only a `t` value)
/// are distinct.
pub const Option = enum {
    /// Event type.
    t,
    /// Chunking indicator: 0 or 1 (1 means more chunks follow).
    m,
    /// Multiplexer id, echoed in all replies for that session.
    i,
    /// Operation: 0 reject, 1 copy, 2 move, 3 either; also reused for
    /// other meanings (e.g. opacity scaled by 1024 in drag images).
    o,
    /// Cell column (or generic 1-based index in request/data events).
    x,
    /// Cell row (or generic 1-based sub-index in request/data events).
    y,
    /// Pixel column (or flag, or directory handle depending on event).
    X,
    /// Pixel row (or directory handle, or image dimension depending on event).
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

    /// Look up an option in the metadata string. Returns null if the key
    /// is absent, malformed, or its value cannot be parsed as the target
    /// type. The default values from the spec are *not* substituted here;
    /// callers should apply defaults via `orelse` so missing-vs-present
    /// can still be distinguished where it matters.
    pub fn read(comptime key: Option, metadata: []const u8) ?key.Type() {
        const name = @tagName(key);

        const value: []const u8 = value: {
            var pos: usize = 0;
            while (pos < metadata.len) {
                // Skip whitespace between options.
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
