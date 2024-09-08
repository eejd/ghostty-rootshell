const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Reader = @import("reader.zig").Reader;

const log = std.log.scoped(.minidump_stream);

/// A stream within the minidump file. A stream can be either in an encoded
/// form or decoded form. The encoded form are raw bytes and aren't validated
/// until they're decoded. The decoded form is a structured form of the stream.
///
/// The decoded form is more ergonomic to work with but the encoded form is
/// more efficient to read/write.
pub const Stream = union(enum) {
    encoded: EncodedStream,
};

/// An encoded stream value. It is "encoded" in the sense that it is raw bytes
/// with a type associated. The raw bytes are not validated to be correct for
/// the type.
pub const EncodedStream = struct {
    type: u32,
    data: []const u8,
};

/// This is the list of threads from the process.
///
/// ThreadList is stream type 0x3.
/// StreamReader is the Reader(T).StreamReader type.
pub fn ThreadList(comptime R: type) type {
    return struct {
        const Self = @This();

        /// The number of threads in the list.
        count: u32,

        /// The rva to the first thread in the list.
        rva: u32,

        /// The source data and endianness so we can continue reading.
        source: R.Source,
        endian: std.builtin.Endian,

        pub fn init(r: *R.StreamReader) !Self {
            assert(r.directory.stream_type == 0x3);
            try r.seekToPayload();

            const reader = r.source.reader();
            const count = try reader.readInt(u32, r.endian);
            const rva = r.directory.location.rva + @as(u32, @intCast(@sizeOf(u32)));

            return .{
                .count = count,
                .rva = rva,
                .source = r.source,
                .endian = r.endian,
            };
        }
    };
}

test "minidump: threadlist" {
    const testing = std.testing;

    var fbs = std.io.fixedBufferStream(@embedFile("../testdata/macos.dmp"));
    const R = Reader(*@TypeOf(fbs));
    const r = try R.init(&fbs);

    // Get our thread list stream
    const dir = try r.directory(0);
    try testing.expectEqual(3, dir.stream_type);
    var sr = try r.streamReader(dir);

    // Get our rich structure
    const v = try ThreadList(R).init(&sr);
    log.warn("threadlist count={} rva={}", .{ v.count, v.rva });
}
