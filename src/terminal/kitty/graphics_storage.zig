const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Image = @import("graphics_image.zig").Image;
const command = @import("graphics_command.zig");
const Command = command.Command;

/// An image storage is associated with a terminal screen (i.e. main
/// screen, alt screen) and contains all the transmitted images and
/// placements.
pub const ImageStorage = struct {
    /// The hash map type used to store our images. The key is the image ID
    /// and the value is the image itself.
    ///
    /// Note that the image ID is optional when transmitting images, in
    /// which case the image ID is always 0.
    const HashMap = std.AutoHashMapUnmanaged(u32, Image);

    /// The set of images that are currently known.
    images: HashMap = .{},

    /// Add an already-loaded image to the storage. This will automatically
    /// free any existing image with the same ID.
    pub fn add(self: *ImageStorage, alloc: Allocator, img: Image) !void {
        const gop = try self.images.getOrPut(alloc, img.id);
        if (gop.found_existing) gop.value_ptr.deinit(alloc);
        gop.value_ptr.* = img;
    }

    pub fn deinit(self: *ImageStorage, alloc: Allocator) void {
        var it = self.images.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(alloc);
        self.images.deinit(alloc);
    }
};
