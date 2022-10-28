//! Renderer implementation for Metal.
pub const Metal = @This();

const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const objc = @import("objc");
const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const Allocator = std.mem.Allocator;

// Get native API access on certain platforms so we can do more customization.
const glfwNative = glfw.Native(.{
    .cocoa = builtin.os.tag == .macos,
});

const log = std.log.scoped(.metal);

/// Current cell dimensions for this grid.
cell_size: renderer.CellSize,

/// Default foreground color
foreground: terminal.color.RGB,

/// Default background color
background: terminal.color.RGB,

/// Metal objects
device: objc.Object, // MTLDevice
queue: objc.Object, // MTLCommandQueue
swapchain: objc.Object, // CAMetalLayer

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

    // We don't do anything else here because we want to set everything
    // else up during actual initialization.
}

pub fn init(alloc: Allocator, font_group: *font.GroupCache) !Metal {
    // Initialize our metal stuff
    const device = objc.Object.fromId(MTLCreateSystemDefaultDevice());
    const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    const swapchain = swapchain: {
        const CAMetalLayer = objc.Class.getClass("CAMetalLayer").?;
        const swapchain = CAMetalLayer.msgSend(objc.Object, objc.sel("layer"), .{});
        swapchain.setProperty("device", device.value);
        swapchain.setProperty("opaque", true);
        break :swapchain swapchain;
    };

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
        .device = device,
        .queue = queue,
        .swapchain = swapchain,
    };
}

pub fn deinit(self: *Metal) void {
    self.* = undefined;
}

/// This is called just prior to spinning up the renderer thread for
/// final main thread setup requirements.
pub fn finalizeInit(self: *const Metal, window: glfw.Window) !void {
    // Set our window backing layer to be our swapchain
    const nswindow = objc.Object.fromId(glfwNative.getCocoaWindow(window).?);
    const contentView = objc.Object.fromId(nswindow.getProperty(?*anyopaque, "contentView").?);
    contentView.setProperty("layer", self.swapchain.value);
    contentView.setProperty("wantsLayer", true);
}

/// Callback called by renderer.Thread when it begins.
pub fn threadEnter(self: *const Metal, window: glfw.Window) !void {
    _ = self;
    _ = window;

    // Metal requires no per-thread state.
}

/// Callback called by renderer.Thread when it exits.
pub fn threadExit(self: *const Metal) void {
    _ = self;

    // Metal requires no per-thread state.
}

/// The primary render callback that is completely thread-safe.
pub fn render(
    self: *Metal,
    window: glfw.Window,
    state: *renderer.State,
) !void {
    _ = window;

    // Data we extract out of the critical area.
    const Critical = struct {
        bg: terminal.color.RGB,
    };

    // Update all our data as tightly as possible within the mutex.
    const critical: Critical = critical: {
        state.mutex.lock();
        defer state.mutex.unlock();

        // Swap bg/fg if the terminal is reversed
        const bg = self.background;
        const fg = self.foreground;
        defer {
            self.background = bg;
            self.foreground = fg;
        }
        if (state.terminal.modes.reverse_colors) {
            self.background = fg;
            self.foreground = bg;
        }

        break :critical .{
            .bg = self.background,
        };
    };

    // @autoreleasepool {}
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);

    // Get our surface (CAMetalDrawable)
    const surface = self.swapchain.msgSend(objc.Object, objc.sel("nextDrawable"), .{});

    // MTLRenderPassDescriptor
    const MTLRenderPassDescriptor = objc.Class.getClass("MTLRenderPassDescriptor").?;
    const desc = desc: {
        const desc = MTLRenderPassDescriptor.msgSend(
            objc.Object,
            objc.sel("renderPassDescriptor"),
            .{},
        );

        // Set our color attachment to be our drawable surface.
        const attachments = objc.Object.fromId(desc.getProperty(?*anyopaque, "colorAttachments"));
        {
            const attachment = attachments.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 0)},
            );

            attachment.setProperty("loadAction", @enumToInt(MTLLoadAction.clear));
            attachment.setProperty("storeAction", @enumToInt(MTLStoreAction.store));
            attachment.setProperty("texture", surface.getProperty(objc.c.id, "texture").?);
            attachment.setProperty("clearColor", MTLClearColor{
                .red = @intToFloat(f32, critical.bg.r) / 255,
                .green = @intToFloat(f32, critical.bg.g) / 255,
                .blue = @intToFloat(f32, critical.bg.b) / 255,
                .alpha = 1.0,
            });
        }

        break :desc desc;
    };

    // Command buffer (MTLCommandBuffer)
    const buffer = self.queue.msgSend(objc.Object, objc.sel("commandBuffer"), .{});

    // MTLRenderCommandEncoder
    const encoder = buffer.msgSend(
        objc.Object,
        objc.sel("renderCommandEncoderWithDescriptor:"),
        .{desc.value},
    );
    encoder.msgSend(void, objc.sel("endEncoding"), .{});

    buffer.msgSend(void, objc.sel("presentDrawable:"), .{surface.value});
    buffer.msgSend(void, objc.sel("commit"), .{});
}

/// https://developer.apple.com/documentation/metal/mtlloadaction?language=objc
const MTLLoadAction = enum(c_ulong) {
    dont_care = 0,
    load = 1,
    clear = 2,
};

/// https://developer.apple.com/documentation/metal/mtlstoreaction?language=objc
const MTLStoreAction = enum(c_ulong) {
    dont_care = 0,
    store = 1,
};

const MTLClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

extern "c" fn MTLCreateSystemDefaultDevice() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(?*anyopaque) void;
