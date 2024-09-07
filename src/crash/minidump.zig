const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.minidump);

/// Minidump parser.
pub const Minidump = struct {
    header: Header,

    /// Read the minidump file for the given source.
    ///
    /// The source must have a reader() and seekableStream() method.
    /// For example, both File and std.io.FixedBufferStream implement these.
    pub fn read(alloc: Allocator, source: anytype) !Minidump {
        _ = alloc;

        // Read the header which also determines the endianness of the file.
        const header, const endian = try readHeader(source);
        log.warn("header={} endian={}", .{ header, endian });

        return .{
            .header = header,
        };
    }

    /// Reads the header for the minidump file and returns endianness of
    /// the file.
    fn readHeader(source: anytype) !struct { Header, std.builtin.Endian } {
        // Start by trying LE.
        var endian: std.builtin.Endian = .little;
        var header = try source.reader().readStructEndian(Header, endian);

        // If the signature doesn't match, we assume its BE.
        if (header.signature != signature) {
            // Seek back to the start of the file so we can reread.
            try source.seekableStream().seekTo(0);

            // Try BE, if the signature doesn't match, return an error.
            endian = .big;
            header = try source.reader().readStructEndian(Header, endian);
            if (header.signature != signature) return error.InvalidHeader;
        }

        // "The low-order word is MINIDUMP_VERSION. The high-order word is an
        // internal value that is implementation specific."
        if (header.version.low != version) return error.InvalidVersion;

        return .{ header, endian };
    }
};

/// "MDMP" in little-endian.
pub const signature = 0x504D444D;

/// The version of the minidump format.
pub const version = 0xA793;

/// https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/ns-minidumpapiset-minidump_header
pub const Header = extern struct {
    signature: u32,
    version: packed struct(u32) { low: u16, high: u16 },
    stream_count: u32,
    stream_directory_rva: u32,
    checksum: u32,
    time_date_stamp: u32,
    flags: u64,
};

test "Minidump read" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var fbs = std.io.fixedBufferStream(@embedFile("testdata/macos.dmp"));
    _ = try Minidump.read(alloc, &fbs);
}
