const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const external = @import("external.zig");
const stream = @import("stream.zig");
const Stream = stream.Stream;

const log = std.log.scoped(.minidump);

/// Minidump file format.
pub const Minidump = struct {
    /// The arena that all streams are allocated within when reading the
    /// minidump file. This is freed on deinit.
    arena: std.heap.ArenaAllocator,

    /// The header of the minidump file. On serialization, the stream count
    /// and rva will be updated to match the streams. On deserialization,
    /// this is read directly from the file.
    header: external.Header,

    /// The streams within the minidump file in the order they're serialized.
    streams: std.ArrayListUnmanaged(Stream),

    /// Read the minidump file for the given source.
    ///
    /// The source must have a reader() and seekableStream() method.
    /// For example, both File and std.io.FixedBufferStream implement these.
    ///
    /// The reader will read the full minidump data into memory. This makes
    /// it easy to serialize the data back out. This is acceptable for our
    /// use case which doesn't rely too much on being memory efficient or
    /// high load. We also expect the minidump files to be relatively small
    /// (dozens of MB at most, hundreds of KB typically).
    ///
    /// NOTE(mitchellh): If we ever want to make this more memory efficient,
    /// I would create a new type that is a "lazy reader" that stores the
    /// source type and reads the data as needed. Then this type should use
    /// that type.
    pub fn read(alloc_gpa: Allocator, source: anytype) !Minidump {
        var arena = std.heap.ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Read the header which also determines the endianness of the file.
        const header, const endian = try readHeader(source);
        //log.warn("header={} endian={}", .{ header, endian });

        var streams = try std.ArrayListUnmanaged(Stream).initCapacity(
            alloc,
            header.stream_count,
        );
        errdefer streams.deinit(alloc);

        // Read the streams. All the streams are first described in a
        // "directory" structure which tells us the type of stream and
        // where it is located in the file. The directory structures are
        // stored in a contiguous block at the stream_directory_rva.
        //
        // Due to how we use this structure, we read directories one by one,
        // then read all the data for that directory, then move on to the
        // next directory. This is because we copy all the minidump data
        // into memory.
        const seeker = source.seekableStream();
        try seeker.seekTo(header.stream_directory_rva);
        for (0..header.stream_count) |_| {
            // Read the current directory
            const directory = try source.reader().readStructEndian(external.Directory, endian);
            log.warn("directory={}", .{directory});

            // Seek to the location of the data. We have to store our current
            // position because we need to seek back to it after reading the
            // data in order to read the next directory.
            const pos = try seeker.getPos();

            try seeker.seekTo(directory.location.rva);

            // Read the data. The data length is defined by the directory.
            // If we can't read exactly that amount of data, we return an error.
            var data = std.ArrayList(u8).init(alloc);
            defer data.deinit();
            source.reader().readAllArrayList(
                &data,
                directory.location.data_size,
            ) catch |err| switch (err) {
                // This means there was more data in the reader than what
                // we asked for this. This is okay and expected because
                // all streams except the last one will have this error.
                error.StreamTooLong => {},
                else => return err,
            };

            // Basic check.
            if (data.items.len != directory.location.data_size) return error.DataSizeMismatch;

            // Store our stream
            try streams.append(alloc, .{ .encoded = .{
                .type = directory.stream_type,
                .data = try data.toOwnedSlice(),
            } });

            // Seek back to where we were after reading this directory
            // entry so we can read the next one.
            try seeker.seekTo(pos);
        }

        return .{
            .arena = arena,
            .header = header,
            .streams = streams,
        };
    }

    /// Reads the header for the minidump file and returns endianness of
    /// the file.
    fn readHeader(source: anytype) !struct { external.Header, std.builtin.Endian } {
        // Start by trying LE.
        var endian: std.builtin.Endian = .little;
        var header = try source.reader().readStructEndian(external.Header, endian);

        // If the signature doesn't match, we assume its BE.
        if (header.signature != external.signature) {
            // Seek back to the start of the file so we can reread.
            try source.seekableStream().seekTo(0);

            // Try BE, if the signature doesn't match, return an error.
            endian = .big;
            header = try source.reader().readStructEndian(external.Header, endian);
            if (header.signature != external.signature) return error.InvalidHeader;
        }

        // "The low-order word is MINIDUMP_VERSION. The high-order word is an
        // internal value that is implementation specific."
        if (header.version.low != external.version) return error.InvalidVersion;

        return .{ header, endian };
    }

    pub fn deinit(self: *Minidump) void {
        self.arena.deinit();
    }

    /// The arena allocator associated with this envelope
    pub fn allocator(self: *Minidump) Allocator {
        return self.arena.allocator();
    }
};

test "Minidump read" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var fbs = std.io.fixedBufferStream(@embedFile("../testdata/macos.dmp"));
    var md = try Minidump.read(alloc, &fbs);
    defer md.deinit();
}
