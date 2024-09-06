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
    /// The arena that the envelope is allocated in. All items are welcome
    /// to use this allocator for their data, which is freed on deinit.
    arena: std.heap.ArenaAllocator,

    /// The headers of the envelope decoded into a json ObjectMap.
    headers: std.json.ObjectMap,

    /// The items in the envelope in the order they're encoded.
    items: []const Item,

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

        return .{ .encoded = .{
            .headers = headers,
            .type = typ,
            .payload = payload,
        } };
    }

    pub fn deinit(self: *Envelope) void {
        self.arena.deinit();
    }

    /// Encode the envelope to the given writer.
    pub fn encode(self: *const Envelope, writer: anytype) !void {
        // Header line first
        try std.json.stringify(std.json.Value{ .object = self.headers }, json_opts, writer);
        try writer.writeByte('\n');

        // Write each item
        for (self.items, 0..) |*item, idx| {
            if (idx > 0) try writer.writeByte('\n');
            try item.encode(writer);
        }
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

/// An item in the envelope. An item can be either in an encoded
/// or decoded state. The encoded state lets us parse the envelope
/// more cheaply since we can defer the full decoding of the item
/// until we need it.
///
/// The decoded state is more ergonomic to work with and lets us
/// easily build up new items and defer encoding until serialization
/// time.
pub const Item = union(enum) {
    encoded: EncodedItem,
    attachment: Attachment,

    pub fn encode(
        self: Item,
        writer: anytype,
    ) !void {
        switch (self) {
            inline .encoded,
            .attachment,
            => |v| try v.encode(writer),
        }
    }

    /// Returns the type of item represented here, whether
    /// it is an encoded item or not.
    pub fn itemType(self: Item) ItemType {
        return switch (self) {
            .encoded => |v| v.type,
            .attachment => .attachment,
        };
    }
};

/// An encoded item. It is "encoded" in the sense that the payload
/// is a byte slice. The headers are "decoded" into a json ObjectMap
/// but that's still a pretty low-level representation.
pub const EncodedItem = struct {
    headers: std.json.ObjectMap,
    type: ItemType,
    payload: []const u8,

    pub fn encode(
        self: EncodedItem,
        writer: anytype,
    ) !void {
        try std.json.stringify(
            std.json.Value{ .object = self.headers },
            json_opts,
            writer,
        );
        try writer.writeByte('\n');
        try writer.writeAll(self.payload);
    }
};

/// An arbitrary file attachment.
///
/// https://develop.sentry.dev/sdk/envelopes/#attachment
pub const Attachment = struct {
    /// "filename" field is the name of the uploaded file without
    /// a path component.
    filename: []const u8,

    /// A special "type" associated with the attachment. This
    /// is documented on the Sentry website. In the future we should
    /// make this an enum.
    type: ?[]const u8 = null,

    /// Additional headers for the attachment.
    header_extra: ObjectMapUnmanaged = .{},

    /// The data for the attachment.
    payload: []const u8,

    pub fn encode(
        self: Attachment,
        writer: anytype,
    ) !void {
        _ = self;
        _ = writer;
        @panic("TODO");
    }
};

/// Same as std.json.ObjectMap but unmanaged. This lets us store
/// them alongside all our items without the overhead of duplicated
/// allocators. Additional, items do not own their own memory so this
/// makes it clear that deinit of an item will not free the memory.
pub const ObjectMapUnmanaged = std.StringArrayHashMapUnmanaged(std.json.Value);

/// The options we must use for serialization.
const json_opts: std.json.StringifyOptions = .{
    // This is the default but I want to be explicit beacuse its
    // VERY important for the correctness of the envelope. This is
    // the only whitespace type in std.json that doesn't emit newlines.
    // All JSON headers in the envelope must be on a single line.
    .whitespace = .minified,
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
    try testing.expectEqual(ItemType.session, v.items[0].encoded.type);
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
    try testing.expectEqual(ItemType.session, v.items[0].encoded.type);
}

test "Envelope encode empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fbs = std.io.fixedBufferStream(
        \\{}
    );
    var v = try Envelope.parse(alloc, fbs.reader());
    defer v.deinit();

    var output = std.ArrayList(u8).init(alloc);
    defer output.deinit();
    try v.encode(output.writer());

    try testing.expectEqualStrings(
        \\{}
    , std.mem.trim(u8, output.items, "\n"));
}

test "Envelope encode session" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fbs = std.io.fixedBufferStream(
        \\{}
        \\{"type":"session","length":218}
        \\{"init":true,"sid":"c148cc2f-5f9f-4231-575c-2e85504d6434","status":"abnormal","errors":0,"started":"2024-08-29T02:38:57.607016Z","duration":0.000343,"attrs":{"release":"0.1.0-HEAD+d37b7d09","environment":"production"}}
    );
    var v = try Envelope.parse(alloc, fbs.reader());
    defer v.deinit();

    var output = std.ArrayList(u8).init(alloc);
    defer output.deinit();
    try v.encode(output.writer());

    try testing.expectEqualStrings(
        \\{}
        \\{"type":"session","length":218}
        \\{"init":true,"sid":"c148cc2f-5f9f-4231-575c-2e85504d6434","status":"abnormal","errors":0,"started":"2024-08-29T02:38:57.607016Z","duration":0.000343,"attrs":{"release":"0.1.0-HEAD+d37b7d09","environment":"production"}}
    , std.mem.trim(u8, output.items, "\n"));
}
