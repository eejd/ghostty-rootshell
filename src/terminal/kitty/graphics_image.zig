const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const command = @import("graphics_command.zig");

const log = std.log.scoped(.kitty_gfx);

/// Maximum width or height of an image. Taken directly from Kitty.
const max_dimension = 10000;

/// Maximum size in bytes, taken from Kitty.
const max_size = 400 * 1024 * 1024; // 400MB

/// An image that is still being loaded. The image should be initialized
/// using init on the first chunk and then addData for each subsequent
/// chunk. Once all chunks have been added, complete should be called
/// to finalize the image.
pub const LoadingImage = struct {
    /// The in-progress image. The first chunk must have all the metadata
    /// so this comes from that initially.
    image: Image,

    /// The data that is being built up.
    data: std.ArrayListUnmanaged(u8) = .{},

    /// Initialize a chunked immage from the first image transmission.
    /// If this is a multi-chunk image, this should only be the FIRST
    /// chunk.
    pub fn init(alloc: Allocator, cmd: *command.Command) !LoadingImage {
        // We must have data to load an image
        if (cmd.data.len == 0) return error.InvalidData;

        // Build our initial image from the properties sent via the control.
        // These can be overwritten by the data loading process. For example,
        // PNG loading sets the width/height from the data.
        const t = cmd.transmission().?;
        var result: LoadingImage = .{
            .image = .{
                .id = t.image_id,
                .number = t.image_number,
                .width = t.width,
                .height = t.height,
                .compression = t.compression,
                .format = switch (t.format) {
                    .rgb => .rgb,
                    .rgba => .rgba,
                    else => unreachable,
                },
            },
        };

        // Load the base64 encoded data from the transmission medium.
        const raw_data = switch (t.medium) {
            .direct => direct: {
                const data = cmd.data;
                _ = cmd.toOwnedData();
                break :direct data;
            },

            else => {
                std.log.warn("unimplemented medium={}", .{t.medium});
                return error.UnsupportedMedium;
            },
        };
        defer alloc.free(raw_data);

        // Add the data
        try result.addData(alloc, raw_data);

        return result;
    }

    pub fn deinit(self: *LoadingImage, alloc: Allocator) void {
        self.image.deinit(alloc);
        self.data.deinit(alloc);
    }

    pub fn destroy(self: *LoadingImage, alloc: Allocator) void {
        self.deinit(alloc);
        alloc.destroy(self);
    }

    /// Adds a chunk of base64-encoded data to the image. Use this if the
    /// image is coming in chunks (the "m" parameter in the protocol).
    pub fn addData(self: *LoadingImage, alloc: Allocator, data: []const u8) !void {
        const Base64Decoder = std.base64.standard.Decoder;

        // Grow our array list by size capacity if it needs it
        const size = Base64Decoder.calcSizeForSlice(data) catch |err| {
            log.warn("failed to calculate size for base64 data: {}", .{err});
            return error.InvalidData;
        };
        try self.data.ensureUnusedCapacity(alloc, size);

        // We decode directly into the arraylist
        const start_i = self.data.items.len;
        self.data.items.len = start_i + size;
        const buf = self.data.items[start_i..];
        Base64Decoder.decode(buf, data) catch |err| {
            log.warn("failed to decode base64 data: {}", .{err});
            return error.InvalidData;
        };
    }

    /// Complete the chunked image, returning a completed image.
    pub fn complete(self: *LoadingImage, alloc: Allocator) !Image {
        const img = &self.image;

        // Validate our dimensions.
        if (img.width == 0 or img.height == 0) return error.DimensionsRequired;
        if (img.width > max_dimension or img.height > max_dimension) return error.DimensionsTooLarge;

        // Decompress the data if it is compressed.
        try self.decompress(alloc);

        // Data length must be what we expect
        const bpp: u32 = switch (img.format) {
            .rgb => 3,
            .rgba => 4,
        };
        const expected_len = img.width * img.height * bpp;
        const actual_len = self.data.items.len;
        std.log.debug(
            "complete image id={} width={} height={} bpp={} expected_len={} actual_len={}",
            .{ img.id, img.width, img.height, bpp, expected_len, actual_len },
        );
        if (actual_len != expected_len) return error.InvalidData;

        // Everything looks good, copy the image data over.
        var result = self.image;
        result.data = try self.data.toOwnedSlice(alloc);
        errdefer result.deinit(alloc);
        self.image = .{};
        return result;
    }

    /// Decompress the data in-place.
    fn decompress(self: *LoadingImage, alloc: Allocator) !void {
        return switch (self.image.compression) {
            .none => {},
            .zlib_deflate => self.decompressZlib(alloc),
        };
    }

    fn decompressZlib(self: *LoadingImage, alloc: Allocator) !void {
        // Open our zlib stream
        var fbs = std.io.fixedBufferStream(self.data.items);
        var stream = std.compress.zlib.decompressStream(alloc, fbs.reader()) catch |err| {
            log.warn("zlib decompression failed: {}", .{err});
            return error.DecompressionFailed;
        };
        defer stream.deinit();

        // Write it to an array list
        var list = std.ArrayList(u8).init(alloc);
        errdefer list.deinit();
        stream.reader().readAllArrayList(&list, max_size) catch |err| {
            log.warn("failed to read decompressed data: {}", .{err});
            return error.DecompressionFailed;
        };

        // Empty our current data list, take ownership over managed array list
        self.data.deinit(alloc);
        self.data = .{ .items = list.items, .capacity = list.capacity };

        // Make sure we note that our image is no longer compressed
        self.image.compression = .none;
    }
};

/// Image represents a single fully loaded image.
pub const Image = struct {
    id: u32 = 0,
    number: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: Format = .rgb,
    compression: command.Transmission.Compression = .none,
    data: []const u8 = "",

    pub const Format = enum { rgb, rgba };

    pub const Error = error{
        InvalidData,
        DecompressionFailed,
        DimensionsRequired,
        DimensionsTooLarge,
        UnsupportedFormat,
        UnsupportedMedium,
    };

    pub fn deinit(self: *Image, alloc: Allocator) void {
        if (self.data.len > 0) alloc.free(self.data);
    }

    /// Mostly for logging
    pub fn withoutData(self: *const Image) Image {
        var copy = self.*;
        copy.data = "";
        return copy;
    }

    /// Debug function to write the data to a file. This is useful for
    /// capturing some test data for unit tests.
    pub fn debugDump(self: Image) !void {
        if (comptime builtin.mode != .Debug) @compileError("debugDump in non-debug");

        var buf: [1024]u8 = undefined;
        const filename = try std.fmt.bufPrint(
            &buf,
            "image-{s}-{s}-{d}x{d}-{}.data",
            .{
                @tagName(self.format),
                @tagName(self.compression),
                self.width,
                self.height,
                self.id,
            },
        );
        const cwd = std.fs.cwd();
        const f = try cwd.createFile(filename, .{});
        defer f.close();

        const writer = f.writer();
        try writer.writeAll(self.data);
    }
};

/// Helper to base64 decode some data. No data is freed.
fn base64Decode(alloc: Allocator, data: []const u8) ![]const u8 {
    const Base64Decoder = std.base64.standard.Decoder;
    const size = Base64Decoder.calcSizeForSlice(data) catch |err| {
        log.warn("failed to calculate base64 decoded size: {}", .{err});
        return error.InvalidData;
    };

    var buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    Base64Decoder.decode(buf, data) catch |err| {
        log.warn("failed to decode base64 data: {}", .{err});
        return error.InvalidData;
    };

    return buf;
}

/// Loads test data from a file path and base64 encodes it.
fn testB64(alloc: Allocator, data: []const u8) ![]const u8 {
    const B64Encoder = std.base64.standard.Encoder;
    var b64 = try alloc.alloc(u8, B64Encoder.calcSize(data.len));
    errdefer alloc.free(b64);
    return B64Encoder.encode(b64, data);
}

// This specifically tests we ALLOW invalid RGB data because Kitty
// documents that this should work.
test "image load with invalid RGB data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // <ESC>_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA<ESC>\
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
}

test "image load with image too wide" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .width = max_dimension + 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, loading.complete(alloc));
}

test "image load with image too tall" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .height = max_dimension + 1,
            .width = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, loading.complete(alloc));
}

test "image load: rgb, zlib compressed, direct" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .zlib_deflate,
            .height = 96,
            .width = 128,
            .image_id = 31,
        } },
        .data = try alloc.dupe(
            u8,
            @embedFile("testdata/image-rgb-zlib_deflate-128x96-2147483647.data"),
        ),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);

    // should be decompressed
    try testing.expect(img.compression == .none);
}

test "image load: rgb, not compressed, direct" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(
            u8,
            @embedFile("testdata/image-rgb-none-20x15-2147483647.data"),
        ),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);

    // should be decompressed
    try testing.expect(img.compression == .none);
}

test "image load: rgb, zlib compressed, direct, chunked" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const data = @embedFile("testdata/image-rgb-zlib_deflate-128x96-2147483647.data");

    // Setup our initial chunk
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .zlib_deflate,
            .height = 96,
            .width = 128,
            .image_id = 31,
            .more_chunks = true,
        } },
        .data = try alloc.dupe(u8, data[0..1024]),
    };
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);

    // Read our remaining chunks
    var fbs = std.io.fixedBufferStream(data[1024..]);
    var buf: [1024]u8 = undefined;
    while (fbs.reader().readAll(&buf)) |size| {
        try loading.addData(alloc, buf[0..size]);
        if (size < buf.len) break;
    } else |err| return err;

    // Complete
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
}
