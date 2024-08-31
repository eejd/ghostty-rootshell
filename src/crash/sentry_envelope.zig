const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// The Sentry Envelope format: https://develop.sentry.dev/sdk/envelopes/
///
/// The envelope is our primary crash report format since use the Sentry
/// client. It is designed and created by Sentry but is an open format
/// in that it is publicly documented and can be used by any system. This
/// lets us utilize the Sentry client for crash capture but also gives us
/// the opportunity to migrate to another system if we need to, and doesn't
/// force any user or developer to use Sentry the SaaS if they don't want
/// to.
///
/// This struct implements reading the envelope format (writing is not needed
/// currently but can be added later). It is incomplete; I only implemented
/// what I needed at the time.
pub const Envelope = struct {
    // Developer note: this struct is really geared towards decoding an
    // already-encoded envelope vs. building up an envelope from rich
    // data types. I think it can be used for both I just didn't have
    // the latter need.
    //
    // If I were to make that ability more enjoyable I'd probably change
    // Item below a tagged union of either an "EncodedItem" (which is the
    // current Item type) or a "DecodedItem" which is a union(ItemType)
    // to its rich data type. This would allow the user to cheaply append
    // items to the envelope without paying the encoding cost until
    // serialization time.
    //
    // The way it is now, the user has to encode every entry as they build
    // the envelope, which is probably fine but I wanted to write this down
    // for my future self or some future contributor since it is fresh
    // in my mind. Cheers.

    /// The arena that the envelope is allocated in.
    arena: std.heap.ArenaAllocator,

    /// The headers of the envelope decoded into a json ObjectMap.
    headers: std.json.ObjectMap,

    /// The items in the envelope in the order they're encoded.
    items: []const Item,

    /// An encoded item. It is "encoded" in the sense that the payload
    /// is a byte slice. The headers are "decoded" into a json ObjectMap
    /// but that's still a pretty low-level representation.
    pub const Item = struct {
        headers: std.json.ObjectMap,
        type: ItemType,
        payload: []const u8,
    };

    /// Parse an envelope from a reader.
    ///
    /// The full envelope must fit in memory for this to succeed. This
    /// will always copy the data from the reader into memory, even if the
    /// reader is already in-memory (i.e. a FixedBufferStream). This
    /// simplifies memory lifetimes at the expense of a copy, but envelope
    /// parsing in our use case is not a hot path.
    pub fn parse(
        alloc_gpa: Allocator,
        reader: anytype,
    ) !Envelope {
        // We use an arena allocator to read from reader. We pair this
        // with `alloc_if_needed` when parsing json to allow the json
        // to reference the arena-allocated memory if it can. That way both
        // our temp and perm memory is part of the same arena. This slightly
        // bloats our memory requirements but reduces allocations.
        var arena = std.heap.ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Parse our elements. We do this outside of the struct assignment
        // below to avoid the issue where order matters in struct assignment.
        const headers = try parseHeader(alloc, reader);
        const items = try parseItems(alloc, reader);

        return .{
            .headers = headers,
            .items = items,
            .arena = arena,
        };
    }

    fn parseHeader(
        alloc: Allocator,
        reader: anytype,
    ) !std.json.ObjectMap {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        reader.streamUntilDelimiter(
            buf.writer(alloc),
            '\n',
            1024 * 1024, // 1MB, arbitrary choice
        ) catch |err| switch (err) {
            // Envelope can be header-only.
            error.EndOfStream => {},
            else => |v| return v,
        };

        const value = try std.json.parseFromSliceLeaky(
            std.json.Value,
            alloc,
            buf.items,
            .{ .allocate = .alloc_if_needed },
        );

        return switch (value) {
            .object => |map| map,
            else => error.EnvelopeMalformedHeaders,
        };
    }

    fn parseItems(
        alloc: Allocator,
        reader: anytype,
    ) ![]const Item {
        var items = std.ArrayList(Item).init(alloc);
        defer items.deinit();
        while (try parseOneItem(alloc, reader)) |item| try items.append(item);
        return try items.toOwnedSlice();
    }

    fn parseOneItem(
        alloc: Allocator,
        reader: anytype,
    ) !?Item {
        // Get the next item which must start with a header.
        var buf: std.ArrayListUnmanaged(u8) = .{};
        reader.streamUntilDelimiter(
            buf.writer(alloc),
            '\n',
            1024 * 1024, // 1MB, arbitrary choice
        ) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |v| return v,
        };

        // Parse the header JSON
        const headers: std.json.ObjectMap = headers: {
            const line = std.mem.trim(u8, buf.items, " \t");
            if (line.len == 0) return null;

            const value = try std.json.parseFromSliceLeaky(
                std.json.Value,
                alloc,
                line,
                .{ .allocate = .alloc_if_needed },
            );

            break :headers switch (value) {
                .object => |map| map,
                else => return error.EnvelopeItemMalformedHeaders,
            };
        };

        // Get the event type
        const typ: ItemType = if (headers.get("type")) |v| switch (v) {
            .string => |str| std.meta.stringToEnum(
                ItemType,
                str,
            ) orelse .unknown,
            else => return error.EnvelopeItemTypeMissing,
        } else return error.EnvelopeItemTypeMissing;

        // Get the payload length. The length is not required. If the length
        // is not specified then it is the next line ending in `\n`.
        const len_: ?u64 = if (headers.get("length")) |v| switch (v) {
            .integer => |int| std.math.cast(
                u64,
                int,
            ) orelse return error.EnvelopeItemLengthMalformed,
            else => return error.EnvelopeItemLengthMalformed,
        } else null;

        // Get the payload
        const payload: []const u8 = if (len_) |len| payload: {
            // The payload length is specified so read the exact length.
            var payload = std.ArrayList(u8).init(alloc);
            defer payload.deinit();
            for (0..len) |_| {
                const byte = reader.readByte() catch |err| switch (err) {
                    error.EndOfStream => return error.EnvelopeItemPayloadTooShort,
                    else => return err,
                };
                try payload.append(byte);
            }
            break :payload try payload.toOwnedSlice();
        } else payload: {
            // The payload is the next line ending in `\n`. It is required.
            var payload = std.ArrayList(u8).init(alloc);
            defer payload.deinit();
            reader.streamUntilDelimiter(
                payload.writer(),
                '\n',
                1024 * 1024 * 50, // 50MB, arbitrary choice
            ) catch |err| switch (err) {
                error.EndOfStream => return error.EnvelopeItemPayloadTooShort,
                else => |v| return v,
            };
            break :payload try payload.toOwnedSlice();
        };

        return .{
            .headers = headers,
            .type = typ,
            .payload = payload,
        };
    }

    pub fn deinit(self: *Envelope) void {
        self.arena.deinit();
    }
};

/// The various item types that can be in an envelope. This is a point
/// in time snapshot of the types that are known whenever this is edited.
/// Event types can be introduced at any time and unknown types will
/// take the "unknown" enum value.
///
/// https://develop.sentry.dev/sdk/envelopes/#data-model
pub const ItemType = enum {
    /// Special event type for when the item type is unknown.
    unknown,

    /// Documented event types
    event,
    transaction,
    attachment,
    session,
    sessions,
    statsd,
    metric_meta,
    user_feedback,
    client_report,
    replay_event,
    replay_recording,
    profile,
    check_in,
};

test "Envelope parse" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fbs = std.io.fixedBufferStream(
        \\{}
    );
    var v = try Envelope.parse(alloc, fbs.reader());
    defer v.deinit();
}

test "Envelope parse session" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fbs = std.io.fixedBufferStream(
        \\{}
        \\{"type":"session","length":218}
        \\{"init":true,"sid":"c148cc2f-5f9f-4231-575c-2e85504d6434","status":"abnormal","errors":0,"started":"2024-08-29T02:38:57.607016Z","duration":0.000343,"attrs":{"release":"0.1.0-HEAD+d37b7d09","environment":"production"}}
    );
    var v = try Envelope.parse(alloc, fbs.reader());
    defer v.deinit();

    try testing.expectEqual(@as(usize, 1), v.items.len);
    try testing.expectEqual(ItemType.session, v.items[0].type);
}

test "Envelope parse end in new line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fbs = std.io.fixedBufferStream(
        \\{}
        \\{"type":"session","length":218}
        \\{"init":true,"sid":"c148cc2f-5f9f-4231-575c-2e85504d6434","status":"abnormal","errors":0,"started":"2024-08-29T02:38:57.607016Z","duration":0.000343,"attrs":{"release":"0.1.0-HEAD+d37b7d09","environment":"production"}}
        \\
    );
    var v = try Envelope.parse(alloc, fbs.reader());
    defer v.deinit();

    try testing.expectEqual(@as(usize, 1), v.items.len);
    try testing.expectEqual(ItemType.session, v.items[0].type);
}
