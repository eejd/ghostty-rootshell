//! Renderer implementation for Metal.
pub const Metal = @This();

const std = @import("std");
const glfw = @import("glfw");
const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.metal);

/// Current cell dimensions for this grid.
cell_size: renderer.CellSize,

/// Default foreground color
foreground: terminal.color.RGB,

/// Default background color
background: terminal.color.RGB,

/// Returns the hints that we want for this
pub fn windowHints() glfw.Window.Hints {
    return .{
        .client_api = .no_api,
        // .cocoa_graphics_switching = builtin.os.tag == .macos,
        // .cocoa_retina_framebuffer = true,
    };
}

/// This is called early right after window creation to setup our
/// window surface as necessary.
pub fn windowInit(window: glfw.Window) !void {
    _ = window;
}

pub fn init(alloc: Allocator, font_group: *font.GroupCache) !Metal {
    // Get our cell metrics based on a regular font ascii 'M'. Why 'M'?
    // Doesn't matter, any normal ASCII will do we're just trying to make
    // sure we use the regular font.
    const metrics = metrics: {
        const index = (try font_group.indexForCodepoint(alloc, 'M', .regular, .text)).?;
        const face = try font_group.group.faceFromIndex(index);
        break :metrics face.metrics;
    };
    log.debug("cell dimensions={}", .{metrics});

    return Metal{
        .cell_size = .{ .width = metrics.cell_width, .height = metrics.cell_height },
        .background = .{ .r = 0, .g = 0, .b = 0 },
        .foreground = .{ .r = 255, .g = 255, .b = 255 },
    };
}

pub fn deinit(self: *Metal) void {
    self.* = undefined;
}

/// This is called just prior to spinning up the renderer thread for
/// final main thread setup requirements.
pub fn finalizeInit(self: *const Metal, window: glfw.Window) !void {
    _ = self;
    _ = window;
}

/// Callback called by renderer.Thread when it begins.
pub fn threadEnter(self: *const Metal, window: glfw.Window) !void {
    _ = self;
    _ = window;
}

/// Callback called by renderer.Thread when it exits.
pub fn threadExit(self: *const Metal) void {
    _ = self;
}

/// The primary render callback that is completely thread-safe.
pub fn render(
    self: *Metal,
    window: glfw.Window,
    state: *renderer.State,
) !void {
    _ = self;
    _ = window;
    _ = state;
}
