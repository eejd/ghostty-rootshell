const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const command = @import("graphics_command.zig");

const log = std.log.scoped(.kitty_gfx);

/// Maximum width or height of an image. Taken directly from Kitty.
const max_dimension = 10000;

/// A chunked image is an image that is in-progress and being constructed
/// using chunks (the "m" parameter in the protocol).
pub const ChunkedImage = struct {
    /// The in-progress image. The first chunk must have all the metadata
    /// so this comes from that initially.
    image: Image,

    /// The data that is being built up.
    data: std.ArrayListUnmanaged(u8) = .{},

    /// Initialize a chunked image from the first image part.
    pub fn init(alloc: Allocator, image: Image) !ChunkedImage {
        // Copy our initial set of data
        var data = try std.ArrayListUnmanaged(u8).initCapacity(alloc, image.data.len * 2);
        errdefer data.deinit(alloc);
        try data.appendSlice(alloc, image.data);

        // Set data to empty so it doesn't get freed.
        var result: ChunkedImage = .{ .image = image, .data = data };
        result.image.data = "";
        return result;
    }

    pub fn deinit(self: *ChunkedImage, alloc: Allocator) void {
        self.image.deinit(alloc);
        self.data.deinit(alloc);
    }

    pub fn destroy(self: *ChunkedImage, alloc: Allocator) void {
        self.deinit(alloc);
        alloc.destroy(self);
    }

    /// Complete the chunked image, returning a completed image.
    pub fn complete(self: *ChunkedImage, alloc: Allocator) !Image {
        var result = self.image;
        result.data = try self.data.toOwnedSlice(alloc);
        self.image = .{};
        return result;
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

    /// The length of the data in bytes, uncompressed. While this will
    /// decompress compressed data to count the bytes it doesn't actually
    /// store the decompressed data so this doesn't allocate much.
    pub fn dataLen(self: *const Image, alloc: Allocator) !usize {
        return switch (self.compression) {
            .none => self.data.len,
            .zlib_deflate => zlib: {
                var fbs = std.io.fixedBufferStream(self.data);

                var stream = std.compress.zlib.decompressStream(alloc, fbs.reader()) catch |err| {
                    log.warn("zlib decompression failed: {}", .{err});
                    return error.DecompressionFailed;
                };
                defer stream.deinit();

                var counting_stream = std.io.countingReader(stream.reader());
                const counting_reader = counting_stream.reader();

                var buf: [4096]u8 = undefined;
                while (counting_reader.readAll(&buf)) |_| {} else |err| {
                    if (err != error.EndOfStream) {
                        log.warn("zlib decompression failed: {}", .{err});
                        return error.DecompressionFailed;
                    }
                }

                break :zlib counting_stream.bytes_read;
            },
        };
    }

    /// Complete the image. This must be called after loading and after
    /// being sure the data is complete (not chunked).
    pub fn complete(self: *Image, alloc: Allocator) !void {
        const bpp: u32 = switch (self.format) {
            .rgb => 3,
            .rgba => 4,
        };

        // Validate our dimensions.
        if (self.width == 0 or self.height == 0) return error.DimensionsRequired;
        if (self.width > max_dimension or self.height > max_dimension) return error.DimensionsTooLarge;

        // The data is base64 encoded, we must decode it.
        var decoded = decoded: {
            const Base64Decoder = std.base64.standard.Decoder;
            const size = Base64Decoder.calcSizeForSlice(self.data) catch |err| {
                log.warn("failed to calculate base64 decoded size: {}", .{err});
                return error.InvalidData;
            };

            var buf = try alloc.alloc(u8, size);
            errdefer alloc.free(buf);
            Base64Decoder.decode(buf, self.data) catch |err| {
                log.warn("failed to decode base64 data: {}", .{err});
                return error.InvalidData;
            };

            break :decoded buf;
        };

        // After decoding, we swap the data immediately and free the old.
        // This will ensure that we never leak memory.
        alloc.free(self.data);
        self.data = decoded;

        // Data length must be what we expect
        const expected_len = self.width * self.height * bpp;
        const actual_len = try self.dataLen(alloc);
        std.log.warn(
            "width={} height={} bpp={} expected_len={} actual_len={}",
            .{ self.width, self.height, bpp, expected_len, actual_len },
        );
        if (actual_len != expected_len) return error.InvalidData;
    }

    /// Load an image from a transmission. The data in the command will be
    /// owned by the image if successful. Note that you still must deinit
    /// the command, all the state change will be done internally.
    ///
    /// If the command represents a chunked image then this image will
    /// be incomplete. The caller is expected to inspect the command
    /// and determine if it is a chunked image.
    pub fn load(alloc: Allocator, cmd: *command.Command) !Image {
        const t = cmd.transmission().?;

        // Load the data
        const data = switch (t.medium) {
            .direct => cmd.data,
            else => {
                std.log.warn("unimplemented medium={}", .{t.medium});
                return error.UnsupportedMedium;
            },
        };

        // If we loaded an image successfully then we take ownership
        // of the command data and we need to make sure to clean up on error.
        _ = cmd.toOwnedData();
        errdefer if (data.len > 0) alloc.free(data);

        const img = switch (t.format) {
            .rgb, .rgba => try loadPacked(t, data),
            else => return error.UnsupportedFormat,
        };

        return img;
    }

    /// Load a package image format, i.e. RGB or RGBA.
    fn loadPacked(
        t: command.Transmission,
        data: []const u8,
    ) !Image {
        return Image{
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
            .data = data,
        };
    }

    pub fn deinit(self: *Image, alloc: Allocator) void {
        if (self.data.len > 0) alloc.free(self.data);
    }

    /// Mostly for logging
    pub fn withoutData(self: *const Image) Image {
        var copy = self.*;
        copy.data = "";
        return copy;
    }
};

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
    var img = try Image.load(alloc, &cmd);
    defer img.deinit(alloc);
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
    var img = try Image.load(alloc, &cmd);
    defer img.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, img.complete(alloc));
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
    var img = try Image.load(alloc, &cmd);
    defer img.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, img.complete(alloc));
}
