//! Renderer implementation for Metal.
pub const Metal = @This();

const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const objc = @import("objc");
const macos = @import("macos");
const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const math = @import("../math.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Terminal = terminal.Terminal;

// Get native API access on certain platforms so we can do more customization.
const glfwNative = glfw.Native(.{
    .cocoa = builtin.os.tag == .macos,
});

const log = std.log.scoped(.metal);

/// Allocator that can be used
alloc: std.mem.Allocator,

/// Current cell dimensions for this grid.
cell_size: renderer.CellSize,

/// Default foreground color
foreground: terminal.color.RGB,

/// Default background color
background: terminal.color.RGB,

/// The current set of cells to render. This is rebuilt on every frame
/// but we keep this around so that we don't reallocate.
cells: std.ArrayListUnmanaged(GPUCell),

/// The font structures.
font_group: *font.GroupCache,
font_shaper: font.Shaper,

/// Metal objects
device: objc.Object, // MTLDevice
queue: objc.Object, // MTLCommandQueue
swapchain: objc.Object, // CAMetalLayer
buf_cells: objc.Object, // MTLBuffer
buf_instance: objc.Object, // MTLBuffer
pipeline: objc.Object, // MTLRenderPipelineState

const GPUCell = extern struct {
    foo: f64,
};

const GPUUniforms = extern struct {
    projection_matrix: math.Mat,
    cell_size: [2]f32,
};

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

    // Create the font shaper. We initially create a shaper that can support
    // a width of 160 which is a common width for modern screens to help
    // avoid allocations later.
    var shape_buf = try alloc.alloc(font.Shaper.Cell, 160);
    errdefer alloc.free(shape_buf);
    var font_shaper = try font.Shaper.init(shape_buf);
    errdefer font_shaper.deinit();

    // Initialize our Metal buffers
    const buf_instance = buffer: {
        const data = [6]u16{
            0, 1, 3, // Top-left triangle
            1, 2, 3, // Bottom-right triangle
        };

        break :buffer device.msgSend(
            objc.Object,
            objc.sel("newBufferWithBytes:length:options:"),
            .{
                @ptrCast(*const anyopaque, &data),
                @intCast(c_ulong, data.len * @sizeOf(u16)),
                MTLResourceStorageModeShared,
            },
        );
    };

    const buf_cells = buffer: {
        const data = [9]f32{
            0,  1,  0,
            -1, -1, 0,
            1,  -1, 0,
        };

        break :buffer device.msgSend(
            objc.Object,
            objc.sel("newBufferWithBytes:length:options:"),
            .{
                @ptrCast(*const anyopaque, &data),
                @intCast(c_ulong, data.len * @sizeOf(f32)),
                MTLResourceStorageModeShared,
            },
        );
    };

    // Initialize our shader (MTLLibrary)
    const library = library: {
        // Load our source into a CFString
        const source = try macos.foundation.String.createWithBytes(
            @embedFile("../shaders/cell.metal"),
            .utf8,
            false,
        );
        defer source.release();

        // Compile
        var err: ?*anyopaque = null;
        const library = device.msgSend(
            objc.Object,
            objc.sel("newLibraryWithSource:options:error:"),
            .{
                source,
                @as(?*anyopaque, null),
                &err,
            },
        );

        // If there is an error (shouldn't since we test), report it and exit.
        if (err != null) {
            const nserr = objc.Object.fromId(err);
            const str = @ptrCast(
                *macos.foundation.String,
                nserr.getProperty(?*anyopaque, "localizedDescription").?,
            );

            log.err("shader error={s}", .{str.cstringPtr(.ascii).?});
            return error.MetalFailed;
        }

        break :library library;
    };
    const func_vert = func_vert: {
        const str = try macos.foundation.String.createWithBytes(
            "basic_vertex",
            .utf8,
            false,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_vert objc.Object.fromId(ptr.?);
    };
    const func_frag = func_frag: {
        const str = try macos.foundation.String.createWithBytes(
            "basic_fragment",
            .utf8,
            false,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_frag objc.Object.fromId(ptr.?);
    };

    const pipeline_state = pipeline_state: {
        // Create our descriptor
        const desc = init: {
            const Class = objc.Class.getClass("MTLRenderPipelineDescriptor").?;
            const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
            const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
            break :init id_init;
        };

        // Set our properties
        desc.setProperty("vertexFunction", func_vert);
        desc.setProperty("fragmentFunction", func_frag);

        // Set our color attachment
        const attachments = objc.Object.fromId(desc.getProperty(?*anyopaque, "colorAttachments"));
        {
            const attachment = attachments.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 0)},
            );

            // Value is MTLPixelFormatBGRA8Unorm
            attachment.setProperty("pixelFormat", @as(c_ulong, 80));
        }

        // Make our state
        var err: ?*anyopaque = null;
        const pipeline_state = device.msgSend(
            objc.Object,
            objc.sel("newRenderPipelineStateWithDescriptor:error:"),
            .{ desc, &err },
        );
        try checkError(err);

        break :pipeline_state pipeline_state;
    };

    return Metal{
        .alloc = alloc,
        .cell_size = .{ .width = metrics.cell_width, .height = metrics.cell_height },
        .background = .{ .r = 0, .g = 0, .b = 0 },
        .foreground = .{ .r = 255, .g = 255, .b = 255 },

        // Render state
        .cells = .{},

        // Fonts
        .font_group = font_group,
        .font_shaper = font_shaper,

        // Metal stuff
        .device = device,
        .queue = queue,
        .swapchain = swapchain,
        .buf_cells = buf_cells,
        .buf_instance = buf_instance,
        .pipeline = pipeline_state,
    };
}

pub fn deinit(self: *Metal) void {
    self.cells.deinit(self.alloc);

    self.font_shaper.deinit();
    self.alloc.free(self.font_shaper.cell_buf);

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

        // If we're resizing, then handle that now.
        if (state.resize_screen) |size| try self.setScreenSize(size);
        defer state.resize_screen = null;

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

        // Build our GPU cells
        try self.rebuildCells(state.terminal);

        break :critical .{
            .bg = self.background,
        };
    };

    // @autoreleasepool {}
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);

    // Ensure our layer size is always updated
    const bounds = self.swapchain.getProperty(macos.graphics.Rect, "bounds");
    self.swapchain.setProperty("drawableSize", bounds.size);

    // Setup our uniforms
    const uniforms: GPUUniforms = .{
        .projection_matrix = math.ortho2d(
            0,
            @floatCast(f32, bounds.size.width),
            @floatCast(f32, bounds.size.height),
            0,
        ),

        // TODO: get content scale to scale these
        .cell_size = .{ self.cell_size.width / 2, self.cell_size.height / 2 },
    };

    // Get our surface (CAMetalDrawable)
    const surface = self.swapchain.msgSend(objc.Object, objc.sel("nextDrawable"), .{});

    // MTLRenderPassDescriptor
    const desc = desc: {
        const MTLRenderPassDescriptor = objc.Class.getClass("MTLRenderPassDescriptor").?;
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

    {
        // MTLRenderCommandEncoder
        const encoder = buffer.msgSend(
            objc.Object,
            objc.sel("renderCommandEncoderWithDescriptor:"),
            .{desc.value},
        );
        defer encoder.msgSend(void, objc.sel("endEncoding"), .{});

        //do we need to do this?
        //encoder.msgSend(void, objc.sel("setViewport:"), .{viewport});

        // Use our shader pipeline
        encoder.msgSend(void, objc.sel("setRenderPipelineState:"), .{self.pipeline.value});

        // Set our buffers
        encoder.msgSend(
            void,
            objc.sel("setVertexBuffer:offset:atIndex:"),
            .{ self.buf_cells.value, @as(c_ulong, 0), @as(c_ulong, 0) },
        );
        encoder.msgSend(
            void,
            objc.sel("setVertexBytes:length:atIndex:"),
            .{
                @ptrCast(*const anyopaque, &uniforms),
                @as(c_ulong, @sizeOf(@TypeOf(uniforms))),
                @as(c_ulong, 1),
            },
        );

        // Draw
        // encoder.msgSend(
        //     void,
        //     objc.sel("drawPrimitives:vertexStart:vertexCount:instanceCount:"),
        //     .{
        //         @enumToInt(MTLPrimitiveType.triangle),
        //         @as(c_ulong, 0),
        //         @as(c_ulong, 3),
        //         @as(c_ulong, 1),
        //     },
        // );

        encoder.msgSend(
            void,
            objc.sel("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:"),
            .{
                @enumToInt(MTLPrimitiveType.triangle),
                @as(c_ulong, 6),
                @enumToInt(MTLIndexType.uint16),
                self.buf_instance.value,
                @as(c_ulong, 0),
                @as(c_ulong, 1),
            },
        );
    }

    buffer.msgSend(void, objc.sel("presentDrawable:"), .{surface.value});
    buffer.msgSend(void, objc.sel("commit"), .{});
}

/// Resize the screen.
fn setScreenSize(self: *Metal, dim: renderer.ScreenSize) !void {
    // Recalculate the rows/columns.
    const grid_size = renderer.GridSize.init(dim, self.cell_size);

    // Update our shaper
    // TODO: don't reallocate if it is close enough (but bigger)
    var shape_buf = try self.alloc.alloc(font.Shaper.Cell, grid_size.columns * 2);
    errdefer self.alloc.free(shape_buf);
    self.alloc.free(self.font_shaper.cell_buf);
    self.font_shaper.cell_buf = shape_buf;

    log.debug("screen size screen={} grid={}, cell={}", .{ dim, grid_size, self.cell_size });
}

/// Sync all the CPU cells with the GPU state (but still on the CPU here).
/// This builds all our "GPUCells" on this struct, but doesn't send them
/// down to the GPU yet.
fn rebuildCells(self: *Metal, term: *Terminal) !void {
    // Over-allocate just to ensure we don't allocate again during loops.
    self.cells.clearRetainingCapacity();
    try self.cells.ensureTotalCapacity(
        self.alloc,

        // * 3 for background modes and cursor and underlines
        // + 1 for cursor
        (term.screen.rows * term.screen.cols * 3) + 1,
    );

    // // Build each cell
    // var rowIter = term.screen.rowIterator(.viewport);
    // var y: usize = 0;
    // while (rowIter.next()) |row| {
    //     defer y += 1;
    //
    //     // Split our row into runs and shape each one.
    //     var iter = self.font_shaper.runIterator(self.font_group, row);
    //     while (try iter.next(self.alloc)) |run| {
    //         for (try self.font_shaper.shape(run)) |shaper_cell| {
    //             assert(try self.updateCell(
    //                 term,
    //                 row.getCell(shaper_cell.x),
    //                 shaper_cell,
    //                 run,
    //                 shaper_cell.x,
    //                 y,
    //             ));
    //         }
    //     }
    //
    //     // Set row is not dirty anymore
    //     row.setDirty(false);
    // }
}

pub fn updateCell(
    self: *Metal,
    term: *Terminal,
    cell: terminal.Screen.Cell,
    shaper_cell: font.Shaper.Cell,
    shaper_run: font.Shaper.TextRun,
    x: usize,
    y: usize,
) !bool {
    _ = shaper_cell;
    _ = shaper_run;

    const BgFg = struct {
        /// Background is optional because in un-inverted mode
        /// it may just be equivalent to the default background in
        /// which case we do nothing to save on GPU render time.
        bg: ?terminal.color.RGB,

        /// Fg is always set to some color, though we may not render
        /// any fg if the cell is empty or has no attributes like
        /// underline.
        fg: terminal.color.RGB,
    };

    // The colors for the cell.
    const colors: BgFg = colors: {
        // If we have a selection, then we need to check if this
        // cell is selected.
        // TODO(perf): we can check in advance if selection is in
        // our viewport at all and not run this on every point.
        if (term.selection) |sel| {
            const screen_point = (terminal.point.Viewport{
                .x = x,
                .y = y,
            }).toScreen(&term.screen);

            // If we are selected, we our colors are just inverted fg/bg
            if (sel.contains(screen_point)) {
                break :colors BgFg{
                    .bg = self.foreground,
                    .fg = self.background,
                };
            }
        }

        const res: BgFg = if (!cell.attrs.inverse) .{
            // In normal mode, background and fg match the cell. We
            // un-optionalize the fg by defaulting to our fg color.
            .bg = if (cell.attrs.has_bg) cell.bg else null,
            .fg = if (cell.attrs.has_fg) cell.fg else self.foreground,
        } else .{
            // In inverted mode, the background MUST be set to something
            // (is never null) so it is either the fg or default fg. The
            // fg is either the bg or default background.
            .bg = if (cell.attrs.has_fg) cell.fg else self.foreground,
            .fg = if (cell.attrs.has_bg) cell.bg else self.background,
        };
        break :colors res;
    };

    // Alpha multiplier
    const alpha: u8 = if (cell.attrs.faint) 175 else 255;

    // If the cell has a background, we always draw it.
    // if (colors.bg) |rgb| {
    //     self.cells.appendAssumeCapacity(.{
    //         .grid_col = @intCast(u16, x),
    //         .grid_row = @intCast(u16, y),
    //         .grid_width = cell.widthLegacy(),
    //         .fg_r = 0,
    //         .fg_g = 0,
    //         .fg_b = 0,
    //         .fg_a = 0,
    //         .bg_r = rgb.r,
    //         .bg_g = rgb.g,
    //         .bg_b = rgb.b,
    //         .bg_a = alpha,
    //     });
    // }
    _ = alpha;
    _ = colors;

    return true;
}

fn checkError(err_: ?*anyopaque) !void {
    if (err_) |err| {
        const nserr = objc.Object.fromId(err);
        const str = @ptrCast(
            *macos.foundation.String,
            nserr.getProperty(?*anyopaque, "localizedDescription").?,
        );

        log.err("metal error={s}", .{str.cstringPtr(.ascii).?});
        return error.MetalFailed;
    }
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

/// https://developer.apple.com/documentation/metal/mtlstoragemode?language=objc
const MTLStorageMode = enum(c_ulong) {
    shared = 0,
    managed = 1,
    private = 2,
    memoryless = 3,
};

/// https://developer.apple.com/documentation/metal/mtlprimitivetype?language=objc
const MTLPrimitiveType = enum(c_ulong) {
    point = 0,
    line = 1,
    line_strip = 2,
    triangle = 3,
    triangle_strip = 4,
};

/// https://developer.apple.com/documentation/metal/mtlindextype?language=objc
const MTLIndexType = enum(c_ulong) {
    uint16 = 0,
    uint32 = 1,
};

/// https://developer.apple.com/documentation/metal/mtlresourceoptions?language=objc
/// (incomplete, we only use this mode so we just hardcode it)
const MTLResourceStorageModeShared: c_ulong = @enumToInt(MTLStorageMode.shared) << 4;

const MTLClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

const MTLViewport = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    znear: f64,
    zfar: f64,
};

extern "c" fn MTLCreateSystemDefaultDevice() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(?*anyopaque) void;
