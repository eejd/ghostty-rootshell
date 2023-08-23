const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const terminal = @import("../main.zig");
const point = @import("../point.zig");
const command = @import("graphics_command.zig");
const Screen = @import("../Screen.zig");
const LoadingImage = @import("graphics_image.zig").LoadingImage;
const Image = @import("graphics_image.zig").Image;
const Command = command.Command;
const ScreenPoint = point.ScreenPoint;

const log = std.log.scoped(.kitty_gfx);

/// An image storage is associated with a terminal screen (i.e. main
/// screen, alt screen) and contains all the transmitted images and
/// placements.
pub const ImageStorage = struct {
    const ImageMap = std.AutoHashMapUnmanaged(u32, Image);
    const PlacementMap = std.AutoHashMapUnmanaged(PlacementKey, Placement);

    /// Dirty is set to true if placements or images change. This is
    /// purely informational for the renderer and doesn't affect the
    /// correctness of the program. The renderer must set this to false
    /// if it cares about this value.
    dirty: bool = false,

    /// This is the next automatically assigned ID. We start mid-way
    /// through the u32 range to avoid collisions with buggy programs.
    next_id: u32 = 2147483647,

    /// The set of images that are currently known.
    images: ImageMap = .{},

    /// The set of placements for loaded images.
    placements: PlacementMap = .{},

    /// Non-null if there is an in-progress loading image.
    loading: ?*LoadingImage = null,

    pub fn deinit(self: *ImageStorage, alloc: Allocator) void {
        if (self.loading) |loading| loading.destroy(alloc);

        var it = self.images.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(alloc);
        self.images.deinit(alloc);

        self.placements.deinit(alloc);
    }

    /// Add an already-loaded image to the storage. This will automatically
    /// free any existing image with the same ID.
    pub fn addImage(self: *ImageStorage, alloc: Allocator, img: Image) Allocator.Error!void {
        // Do the gop op first so if it fails we don't get a partial state
        const gop = try self.images.getOrPut(alloc, img.id);

        log.debug("addImage image={}", .{img: {
            var copy = img;
            copy.data = "";
            break :img copy;
        }});

        // If the image has an image number, we need to invalidate the last
        // image with that same number.
        if (img.number > 0) {
            var it = self.images.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.number == img.number) {
                    kv.value_ptr.number = 0;
                    break;
                }
            }
        }

        // Write our new image
        if (gop.found_existing) gop.value_ptr.deinit(alloc);
        gop.value_ptr.* = img;

        self.dirty = true;
    }

    /// Add a placement for a given image. The caller must verify in advance
    /// the image exists to prevent memory corruption.
    pub fn addPlacement(
        self: *ImageStorage,
        alloc: Allocator,
        image_id: u32,
        placement_id: u32,
        p: Placement,
    ) !void {
        assert(self.images.get(image_id) != null);
        log.debug("placement image_id={} placement_id={} placement={}\n", .{
            image_id,
            placement_id,
            p,
        });

        const key: PlacementKey = .{ .image_id = image_id, .placement_id = placement_id };
        const gop = try self.placements.getOrPut(alloc, key);
        gop.value_ptr.* = p;

        self.dirty = true;
    }

    /// Get an image by its ID. If the image doesn't exist, null is returned.
    pub fn imageById(self: *const ImageStorage, image_id: u32) ?Image {
        return self.images.get(image_id);
    }

    /// Get an image by its number. If the image doesn't exist, return null.
    pub fn imageByNumber(self: *const ImageStorage, image_number: u32) ?Image {
        var it = self.images.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.number == image_number) return kv.value_ptr.*;
        }

        return null;
    }

    /// Delete placements, images.
    pub fn delete(
        self: *ImageStorage,
        alloc: Allocator,
        screen: *const Screen,
        cmd: command.Delete,
    ) void {
        _ = screen;

        switch (cmd) {
            .all => |delete_images| if (delete_images) {
                // We just reset our entire state.
                self.deinit(alloc);
                self.* = .{ .dirty = true };
            } else {
                // Delete all our placements
                self.placements.deinit(alloc);
                self.placements = .{};
                self.dirty = true;
            },

            else => log.warn("unimplemented delete command: {}", .{cmd}),
        }
    }

    /// Every placement is uniquely identified by the image ID and the
    /// placement ID. If an image ID isn't specified it is assumed to be 0.
    /// Likewise, if a placement ID isn't specified it is assumed to be 0.
    pub const PlacementKey = struct {
        image_id: u32,
        placement_id: u32,
    };

    pub const Placement = struct {
        /// The location of the image on the screen.
        point: ScreenPoint,

        /// Offset of the x/y from the top-left of the cell.
        x_offset: u32 = 0,
        y_offset: u32 = 0,

        /// Source rectangle for the image to pull from
        source_x: u32 = 0,
        source_y: u32 = 0,
        source_width: u32 = 0,
        source_height: u32 = 0,

        /// The columns/rows this image occupies.
        columns: u32 = 0,
        rows: u32 = 0,

        /// The z-index for this placement.
        z: i32 = 0,

        /// Returns a selection of the entire rectangle this placement
        /// occupies within the screen.
        pub fn selection(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
        ) terminal.Selection {
            // If we have columns/rows specified we can simplify this whole thing.
            if (self.columns > 0 and self.rows > 0) {
                return terminal.Selection{
                    .start = self.point,
                    .end = .{
                        .x = @min(self.point.x + self.columns, t.cols),
                        .y = @min(self.point.y + self.rows, t.rows),
                    },
                };
            }

            // Calculate our cell size.
            const terminal_width_f64: f64 = @floatFromInt(t.width_px);
            const terminal_height_f64: f64 = @floatFromInt(t.height_px);
            const grid_columns_f64: f64 = @floatFromInt(t.cols);
            const grid_rows_f64: f64 = @floatFromInt(t.rows);
            const cell_width_f64 = terminal_width_f64 / grid_columns_f64;
            const cell_height_f64 = terminal_height_f64 / grid_rows_f64;

            // Our image width
            const width_px = if (self.source_width > 0) self.source_width else image.width;
            const height_px = if (self.source_height > 0) self.source_height else image.height;

            // Calculate our image size in grid cells
            const width_f64: f64 = @floatFromInt(width_px);
            const height_f64: f64 = @floatFromInt(height_px);
            const width_cells: u32 = @intFromFloat(@ceil(width_f64 / cell_width_f64));
            const height_cells: u32 = @intFromFloat(@ceil(height_f64 / cell_height_f64));

            return .{
                .start = self.point,
                .end = .{
                    .x = @min(t.cols - 1, self.point.x + width_cells),
                    .y = self.point.y + height_cells,
                },
            };
        }
    };
};
