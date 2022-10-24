//! This file implements the "dev mode" interface for the terminal. This
//! includes state managements and rendering.
const DevMode = @This();

const std = @import("std");
const imgui = @import("imgui");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Atlas = @import("Atlas.zig");
const Window = @import("Window.zig");

/// If this is false, the rest of the terminal will be compiled without
/// dev mode support at all.
pub const enabled = true;

/// The global DevMode instance that can be used app-wide. Assume all functions
/// are NOT thread-safe unless otherwise noted.
pub var instance: DevMode = .{};

/// Whether to show the dev mode UI currently.
visible: bool = false,

/// The window we're tracking.
window: ?*Window = null,

/// Update the state associated with the dev mode. This should generally
/// only be called paired with a render since it otherwise wastes CPU
/// cycles.
pub fn update(self: *const DevMode) !void {
    imgui.ImplOpenGL3.newFrame();
    imgui.ImplGlfw.newFrame();
    imgui.newFrame();

    if (imgui.begin("dev mode", null, .{})) {
        defer imgui.end();

        if (self.window) |window| {
            if (imgui.collapsingHeader("Font Manager", null, .{})) {
                imgui.text("Glyphs: %d", window.font_group.glyphs.count());
                imgui.sameLine(0, -1);
                helpMarker("The number of glyphs loaded and rendered into a " ++
                    "font atlas currently.");

                if (imgui.treeNode("Atlas: Greyscale", .{ .default_open = true })) {
                    defer imgui.treePop();
                    const atlas = &window.font_group.atlas_greyscale;
                    try self.atlasInfo(atlas, @intCast(usize, window.renderer.texture.id));
                }

                if (imgui.treeNode("Atlas: Color (Emoji)", .{ .default_open = true })) {
                    defer imgui.treePop();
                    const atlas = &window.font_group.atlas_color;
                    try self.atlasInfo(atlas, @intCast(usize, window.renderer.texture_color.id));
                }
            }
        }
    }

    // Just demo for now
    //imgui.showDemoWindow(null);
}

/// Render the scene and return the draw data. The caller must be imgui-aware
/// in order to render the draw data. This lets this file be renderer/backend
/// agnostic.
pub fn render(self: DevMode) !*imgui.DrawData {
    _ = self;
    imgui.render();
    return try imgui.DrawData.get();
}

/// Helper to render a tooltip.
fn helpMarker(desc: [:0]const u8) void {
    imgui.textDisabled("(?)");
    if (imgui.isItemHovered(.{})) {
        imgui.beginTooltip();
        defer imgui.endTooltip();
        imgui.pushTextWrapPos(imgui.getFontSize() * 35);
        defer imgui.popTextWrapPos();
        imgui.text(desc.ptr);
    }
}

fn atlasInfo(self: *const DevMode, atlas: *Atlas, tex: ?usize) !void {
    _ = self;

    imgui.text("Dimensions: %d x %d", atlas.size, atlas.size);
    imgui.sameLine(0, -1);
    helpMarker("The pixel dimensions of the atlas texture.");

    imgui.text("Size: %d KB", atlas.data.len >> 10);
    imgui.sameLine(0, -1);
    helpMarker("The byte size of the atlas texture.");

    var buf: [1024]u8 = undefined;
    imgui.text(
        "Format: %s (depth = %d)",
        (try std.fmt.bufPrintZ(&buf, "{}", .{atlas.format})).ptr,
        atlas.format.depth(),
    );
    imgui.sameLine(0, -1);
    helpMarker("The internal storage format of this atlas.");

    if (tex) |id| {
        imgui.c.igImage(
            @intToPtr(*anyopaque, id),
            .{
                .x = @intToFloat(f32, atlas.size),
                .y = @intToFloat(f32, atlas.size),
            },
            .{ .x = 0, .y = 0 },
            .{ .x = 1, .y = 1 },
            .{ .x = 1, .y = 1, .z = 1, .w = 1 },
            .{ .x = 0, .y = 0, .z = 0, .w = 0 },
        );
    }
}
