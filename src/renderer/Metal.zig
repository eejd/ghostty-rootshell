//! Renderer implementation for Metal.
//!
//! Open questions:
//!
pub const Metal = @This();

const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const objc = @import("objc");
const macos = @import("macos");
const imgui = @import("imgui");
const Atlas = @import("../Atlas.zig");
const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const math = @import("../math.zig");
const DevMode = @import("../DevMode.zig");
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

/// True if the window is focused
focused: bool,

/// Whether the cursor is visible or not. This is used to control cursor
/// blinking.
cursor_visible: bool,
cursor_style: renderer.CursorStyle,

/// Default foreground color
foreground: terminal.color.RGB,

/// Default background color
background: terminal.color.RGB,

/// The current set of cells to render. This is rebuilt on every frame
/// but we keep this around so that we don't reallocate.
cells: std.ArrayListUnmanaged(GPUCell),

/// The current GPU uniform values.
uniforms: GPUUniforms,

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
texture_greyscale: objc.Object, // MTLTexture
texture_color: objc.Object, // MTLTexture

const GPUCell = extern struct {
    mode: GPUCellMode,
    grid_pos: [2]f32,
    cell_width: u8,
    color: [4]u8,
    glyph_pos: [2]u32 = .{ 0, 0 },
    glyph_size: [2]u32 = .{ 0, 0 },
    glyph_offset: [2]i32 = .{ 0, 0 },
};

const GPUUniforms = extern struct {
    /// The projection matrix for turning world coordinates to normalized.
    /// This is calculated based on the size of the screen.
    projection_matrix: math.Mat,

    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32,

    /// Metrics for underline/strikethrough
    underline_position: f32,
    underline_thickness: f32,
    strikethrough_position: f32,
    strikethrough_thickness: f32,
};

const GPUCellMode = enum(u8) {
    bg = 1,
    fg = 2,
    fg_color = 7,
    cursor_rect = 3,
    cursor_rect_hollow = 4,
    cursor_bar = 5,
    underline = 6,
    strikethrough = 8,

    pub fn fromCursor(cursor: renderer.CursorStyle) GPUCellMode {
        return switch (cursor) {
            .box => .cursor_rect,
            .box_hollow => .cursor_rect_hollow,
            .bar => .cursor_bar,
        };
    }
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

        // disable v-sync
        swapchain.setProperty("displaySyncEnabled", false);

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
        // Preallocate for 160x160 grid with 3 modes (bg, fg, text). This
        // should handle most terminals well, and we can avoid a resize later.
        const prealloc = 160 * 160 * 3;

        break :buffer device.msgSend(
            objc.Object,
            objc.sel("newBufferWithLength:options:"),
            .{
                @intCast(c_ulong, prealloc * @sizeOf(GPUCell)),
                MTLResourceStorageModeShared,
            },
        );
    };

    // Initialize our shader (MTLLibrary)
    const library = try initLibrary(device, @embedFile("../shaders/cell.metal"));
    const pipeline_state = try initPipelineState(device, library);
    const texture_greyscale = try initAtlasTexture(device, &font_group.atlas_greyscale);
    const texture_color = try initAtlasTexture(device, &font_group.atlas_color);

    return Metal{
        .alloc = alloc,
        .cell_size = .{ .width = metrics.cell_width, .height = metrics.cell_height },
        .background = .{ .r = 0, .g = 0, .b = 0 },
        .foreground = .{ .r = 255, .g = 255, .b = 255 },
        .focused = true,
        .cursor_visible = true,
        .cursor_style = .box,

        // Render state
        .cells = .{},
        .uniforms = .{
            .projection_matrix = undefined,
            .cell_size = undefined,
            .underline_position = metrics.underline_position,
            .underline_thickness = metrics.underline_thickness,
            .strikethrough_position = metrics.strikethrough_position,
            .strikethrough_thickness = metrics.strikethrough_thickness,
        },

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
        .texture_greyscale = texture_greyscale,
        .texture_color = texture_color,
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
pub fn finalizeWindowInit(self: *const Metal, window: glfw.Window) !void {
    // Set our window backing layer to be our swapchain
    const nswindow = objc.Object.fromId(glfwNative.getCocoaWindow(window).?);
    const contentView = objc.Object.fromId(nswindow.getProperty(?*anyopaque, "contentView").?);
    contentView.setProperty("layer", self.swapchain.value);
    contentView.setProperty("wantsLayer", true);

    // Ensure that our metal layer has a content scale set to match the
    // scale factor of the window. This avoids magnification issues leading
    // to blurry rendering.
    const layer = contentView.getProperty(objc.Object, "layer");
    const scaleFactor = nswindow.getProperty(macos.graphics.c.CGFloat, "backingScaleFactor");
    layer.setProperty("contentsScale", scaleFactor);
}

/// This is called only after the first window is opened. This may be
/// called multiple times if all windows are closed and a new one is
/// reopened.
pub fn firstWindowInit(self: *const Metal, window: glfw.Window) !void {
    if (DevMode.enabled) {
        // Initialize for our window
        assert(imgui.ImplGlfw.initForOther(
            @ptrCast(*imgui.ImplGlfw.GLFWWindow, window.handle),
            true,
        ));
        assert(imgui.ImplMetal.init(self.device.value));
    }
}

/// This is called only when the last window is destroyed.
pub fn lastWindowDeinit() void {
    if (DevMode.enabled) {
        imgui.ImplMetal.shutdown();
        imgui.ImplGlfw.shutdown();
    }
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

/// Callback when the focus changes for the terminal this is rendering.
pub fn setFocus(self: *Metal, focus: bool) !void {
    self.focused = focus;
}

/// Called to toggle the blink state of the cursor
pub fn blinkCursor(self: *Metal, reset: bool) void {
    self.cursor_visible = reset or !self.cursor_visible;
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
        screen_size: ?renderer.ScreenSize,
        devmode: bool,
    };

    // Update all our data as tightly as possible within the mutex.
    const critical: Critical = critical: {
        state.mutex.lock();
        defer state.mutex.unlock();

        // If we're resizing, then handle that now.
        if (state.resize_screen) |size| try self.setScreenSize(size);
        defer state.resize_screen = null;

        // Setup our cursor state
        if (self.focused) {
            self.cursor_visible = self.cursor_visible and state.cursor.visible;
            self.cursor_style = renderer.CursorStyle.fromTerminal(state.cursor.style) orelse .box;
        } else {
            self.cursor_visible = true;
            self.cursor_style = .box_hollow;
        }

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
            .screen_size = state.resize_screen,
            .devmode = if (state.devmode) |dm| dm.visible else false,
        };
    };

    // @autoreleasepool {}
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);

    // If we're resizing, then we have to update a bunch of things...
    if (critical.screen_size) |screen_size| {
        const bounds = self.swapchain.getProperty(macos.graphics.Rect, "bounds");

        // Scale the bounds based on the layer content scale so that we
        // properly handle Retina.
        const scaled: macos.graphics.Size = scaled: {
            const scaleFactor = self.swapchain.getProperty(macos.graphics.c.CGFloat, "contentsScale");
            break :scaled .{
                .width = bounds.size.width * scaleFactor,
                .height = bounds.size.height * scaleFactor,
            };
        };

        // Set the size of the drawable surface to the scaled bounds
        self.swapchain.setProperty("drawableSize", scaled);
        _ = screen_size;
        //log.warn("bounds={} screen={} scaled={}", .{ bounds, screen_size, scaled });

        // Setup our uniforms
        const old = self.uniforms;
        self.uniforms = .{
            .projection_matrix = math.ortho2d(
                0,
                @floatCast(f32, scaled.width),
                @floatCast(f32, scaled.height),
                0,
            ),
            .cell_size = .{ self.cell_size.width, self.cell_size.height },
            .underline_position = old.underline_position,
            .underline_thickness = old.underline_thickness,
            .strikethrough_position = old.strikethrough_position,
            .strikethrough_thickness = old.strikethrough_thickness,
        };
    }

    // Get our surface (CAMetalDrawable)
    const surface = self.swapchain.msgSend(objc.Object, objc.sel("nextDrawable"), .{});

    // Setup our buffers
    try self.syncCells();

    // If our font atlas changed, sync the texture data
    if (self.font_group.atlas_greyscale.modified) {
        try syncAtlasTexture(self.device, &self.font_group.atlas_greyscale, &self.texture_greyscale);
        self.font_group.atlas_greyscale.modified = false;
    }
    if (self.font_group.atlas_color.modified) {
        try syncAtlasTexture(self.device, &self.font_group.atlas_color, &self.texture_color);
        self.font_group.atlas_color.modified = false;
    }

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
                @ptrCast(*const anyopaque, &self.uniforms),
                @as(c_ulong, @sizeOf(@TypeOf(self.uniforms))),
                @as(c_ulong, 1),
            },
        );
        encoder.msgSend(
            void,
            objc.sel("setFragmentTexture:atIndex:"),
            .{
                self.texture_greyscale.value,
                @as(c_ulong, 0),
            },
        );
        encoder.msgSend(
            void,
            objc.sel("setFragmentTexture:atIndex:"),
            .{
                self.texture_color.value,
                @as(c_ulong, 1),
            },
        );

        encoder.msgSend(
            void,
            objc.sel("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:"),
            .{
                @enumToInt(MTLPrimitiveType.triangle),
                @as(c_ulong, 6),
                @enumToInt(MTLIndexType.uint16),
                self.buf_instance.value,
                @as(c_ulong, 0),
                @as(c_ulong, self.cells.items.len),
            },
        );

        // Build our devmode draw data. This sucks because it requires we
        // lock our state mutex but the metal imgui implementation requires
        // access to all this stuff.
        if (critical.devmode) {
            state.mutex.lock();
            defer state.mutex.unlock();

            if (state.devmode) |dm| {
                if (dm.visible) {
                    imgui.ImplMetal.newFrame(desc.value);
                    imgui.ImplGlfw.newFrame();
                    try dm.update();
                    imgui.ImplMetal.renderDrawData(
                        try dm.render(),
                        buffer.value,
                        encoder.value,
                    );
                }
            }
        }
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

    // This is the cell that has [mode == .fg] and is underneath our cursor.
    // We keep track of it so that we can invert the colors so the character
    // remains visible.
    var cursor_cell: ?GPUCell = null;

    // Build each cell
    var rowIter = term.screen.rowIterator(.viewport);
    var y: usize = 0;
    while (rowIter.next()) |row| {
        defer y += 1;

        // If this is the row with our cursor, then we may have to modify
        // the cell with the cursor.
        const start_i: usize = self.cells.items.len;
        defer if (self.cursor_visible and
            self.cursor_style == .box and
            term.screen.viewportIsBottom() and
            y == term.screen.cursor.y)
        {
            for (self.cells.items[start_i..]) |cell| {
                if (cell.grid_pos[0] == @intToFloat(f32, term.screen.cursor.x) and
                    cell.mode == .fg)
                {
                    cursor_cell = cell;
                    break;
                }
            }
        };

        // Split our row into runs and shape each one.
        var iter = self.font_shaper.runIterator(self.font_group, row);
        while (try iter.next(self.alloc)) |run| {
            for (try self.font_shaper.shape(run)) |shaper_cell| {
                assert(try self.updateCell(
                    term,
                    row.getCell(shaper_cell.x),
                    shaper_cell,
                    run,
                    shaper_cell.x,
                    y,
                ));
            }
        }

        // Set row is not dirty anymore
        row.setDirty(false);
    }

    // Add the cursor at the end so that it overlays everything. If we have
    // a cursor cell then we invert the colors on that and add it in so
    // that we can always see it.
    self.addCursor(term);
    if (cursor_cell) |*cell| {
        cell.color = .{ 0, 0, 0, 255 };
        self.cells.appendAssumeCapacity(cell.*);
    }
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
    if (colors.bg) |rgb| {
        self.cells.appendAssumeCapacity(.{
            .mode = .bg,
            .grid_pos = .{ @intToFloat(f32, x), @intToFloat(f32, y) },
            .cell_width = cell.widthLegacy(),
            .color = .{ rgb.r, rgb.g, rgb.b, alpha },
        });
    }

    // If the cell has a character, draw it
    if (cell.char > 0) {
        // Render
        const glyph = try self.font_group.renderGlyph(
            self.alloc,
            shaper_run.font_index,
            shaper_cell.glyph_index,
            @floatToInt(u16, @ceil(self.cell_size.height)),
        );

        // If we're rendering a color font, we use the color atlas
        const face = try self.font_group.group.faceFromIndex(shaper_run.font_index);
        const mode: GPUCellMode = if (face.presentation == .emoji) .fg_color else .fg;

        self.cells.appendAssumeCapacity(.{
            .mode = mode,
            .grid_pos = .{ @intToFloat(f32, x), @intToFloat(f32, y) },
            .cell_width = cell.widthLegacy(),
            .color = .{ colors.fg.r, colors.fg.g, colors.fg.b, alpha },
            .glyph_pos = .{ glyph.atlas_x, glyph.atlas_y },
            .glyph_size = .{ glyph.width, glyph.height },
            .glyph_offset = .{ glyph.offset_x, glyph.offset_y },
        });
    }

    if (cell.attrs.underline) {
        self.cells.appendAssumeCapacity(.{
            .mode = .underline,
            .grid_pos = .{ @intToFloat(f32, x), @intToFloat(f32, y) },
            .cell_width = cell.widthLegacy(),
            .color = .{ colors.fg.r, colors.fg.g, colors.fg.b, alpha },
        });
    }

    if (cell.attrs.strikethrough) {
        self.cells.appendAssumeCapacity(.{
            .mode = .strikethrough,
            .grid_pos = .{ @intToFloat(f32, x), @intToFloat(f32, y) },
            .cell_width = cell.widthLegacy(),
            .color = .{ colors.fg.r, colors.fg.g, colors.fg.b, alpha },
        });
    }

    return true;
}

fn addCursor(self: *Metal, term: *Terminal) void {
    // Add the cursor
    if (self.cursor_visible and term.screen.viewportIsBottom()) {
        const cell = term.screen.getCell(
            .active,
            term.screen.cursor.y,
            term.screen.cursor.x,
        );

        self.cells.appendAssumeCapacity(.{
            .mode = GPUCellMode.fromCursor(self.cursor_style),
            .grid_pos = .{
                @intToFloat(f32, term.screen.cursor.x),
                @intToFloat(f32, term.screen.cursor.y),
            },
            .cell_width = if (cell.attrs.wide) 2 else 1,
            .color = .{ 0xFF, 0xFF, 0xFF, 0xFF },
        });
    }
}

/// Sync the vertex buffer inputs to the GPU. This will attempt to reuse
/// the existing buffer (of course!) but will allocate a new buffer if
/// our cells don't fit in it.
fn syncCells(self: *Metal) !void {
    const req_bytes = self.cells.items.len * @sizeOf(GPUCell);
    const avail_bytes = self.buf_cells.getProperty(c_ulong, "length");

    // If we need more bytes than our buffer has, we need to reallocate.
    if (req_bytes > avail_bytes) {
        // Deallocate previous buffer
        deinitMTLResource(self.buf_cells);

        // Allocate a new buffer with enough to hold double what we require.
        const size = req_bytes * 2;
        self.buf_cells = self.device.msgSend(
            objc.Object,
            objc.sel("newBufferWithLength:options:"),
            .{
                @intCast(c_ulong, size * @sizeOf(GPUCell)),
                MTLResourceStorageModeShared,
            },
        );
    }

    // We can fit within the vertex buffer so we can just replace bytes.
    const ptr = self.buf_cells.msgSend(?[*]u8, objc.sel("contents"), .{}) orelse {
        log.warn("buf_cells contents ptr is null", .{});
        return error.MetalFailed;
    };

    @memcpy(ptr, @ptrCast([*]const u8, self.cells.items.ptr), req_bytes);
}

/// Sync the atlas data to the given texture. This copies the bytes
/// associated with the atlas to the given texture. If the atlas no longer
/// fits into the texture, the texture will be resized.
fn syncAtlasTexture(device: objc.Object, atlas: *const Atlas, texture: *objc.Object) !void {
    const width = texture.getProperty(c_ulong, "width");
    if (atlas.size > width) {
        // Free our old texture
        deinitMTLResource(texture.*);

        // Reallocate
        texture.* = try initAtlasTexture(device, atlas);
    }

    texture.msgSend(
        void,
        objc.sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
        .{
            MTLRegion{
                .origin = .{ .x = 0, .y = 0, .z = 0 },
                .size = .{
                    .width = @intCast(c_ulong, atlas.size),
                    .height = @intCast(c_ulong, atlas.size),
                    .depth = 1,
                },
            },
            @as(c_ulong, 0),
            atlas.data.ptr,
            @as(c_ulong, atlas.format.depth() * atlas.size),
        },
    );
}

/// Initialize the shader library.
fn initLibrary(device: objc.Object, data: []const u8) !objc.Object {
    const source = try macos.foundation.String.createWithBytes(
        data,
        .utf8,
        false,
    );
    defer source.release();

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
    try checkError(err);

    return library;
}

/// Initialize the render pipeline for our shader library.
fn initPipelineState(device: objc.Object, library: objc.Object) !objc.Object {
    // Get our vertex and fragment functions
    const func_vert = func_vert: {
        const str = try macos.foundation.String.createWithBytes(
            "uber_vertex",
            .utf8,
            false,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_vert objc.Object.fromId(ptr.?);
    };
    const func_frag = func_frag: {
        const str = try macos.foundation.String.createWithBytes(
            "uber_fragment",
            .utf8,
            false,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_frag objc.Object.fromId(ptr.?);
    };

    // Create the vertex descriptor. The vertex descriptor describves the
    // data layout of the vertex inputs. We use indexed (or "instanced")
    // rendering, so this makes it so that each instance gets a single
    // GPUCell as input.
    const vertex_desc = vertex_desc: {
        const desc = init: {
            const Class = objc.Class.getClass("MTLVertexDescriptor").?;
            const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
            const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
            break :init id_init;
        };

        // Our attributes are the fields of the input
        const attrs = objc.Object.fromId(desc.getProperty(?*anyopaque, "attributes"));
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 0)},
            );

            attr.setProperty("format", @enumToInt(MTLVertexFormat.uchar));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(GPUCell, "mode")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 1)},
            );

            attr.setProperty("format", @enumToInt(MTLVertexFormat.float2));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(GPUCell, "grid_pos")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 2)},
            );

            attr.setProperty("format", @enumToInt(MTLVertexFormat.uint2));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(GPUCell, "glyph_pos")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 3)},
            );

            attr.setProperty("format", @enumToInt(MTLVertexFormat.uint2));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(GPUCell, "glyph_size")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 4)},
            );

            attr.setProperty("format", @enumToInt(MTLVertexFormat.int2));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(GPUCell, "glyph_offset")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 5)},
            );

            attr.setProperty("format", @enumToInt(MTLVertexFormat.uchar4));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(GPUCell, "color")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 6)},
            );

            attr.setProperty("format", @enumToInt(MTLVertexFormat.uchar));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(GPUCell, "cell_width")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }

        // The layout describes how and when we fetch the next vertex input.
        const layouts = objc.Object.fromId(desc.getProperty(?*anyopaque, "layouts"));
        {
            const layout = layouts.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 0)},
            );

            // Access each GPUCell per instance, not per vertex.
            layout.setProperty("stepFunction", @enumToInt(MTLVertexStepFunction.per_instance));
            layout.setProperty("stride", @as(c_ulong, @sizeOf(GPUCell)));
        }

        break :vertex_desc desc;
    };

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
    desc.setProperty("vertexDescriptor", vertex_desc);

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

        // Blending. This is required so that our text we render on top
        // of our drawable properly blends into the bg.
        attachment.setProperty("blendingEnabled", true);
        attachment.setProperty("rgbBlendOperation", @enumToInt(MTLBlendOperation.add));
        attachment.setProperty("alphaBlendOperation", @enumToInt(MTLBlendOperation.add));
        attachment.setProperty("sourceRGBBlendFactor", @enumToInt(MTLBlendFactor.source_alpha));
        attachment.setProperty("sourceAlphaBlendFactor", @enumToInt(MTLBlendFactor.source_alpha));
        attachment.setProperty("destinationRGBBlendFactor", @enumToInt(MTLBlendFactor.one_minus_source_alpha));
        attachment.setProperty("destinationAlphaBlendFactor", @enumToInt(MTLBlendFactor.one_minus_source_alpha));
    }

    // Make our state
    var err: ?*anyopaque = null;
    const pipeline_state = device.msgSend(
        objc.Object,
        objc.sel("newRenderPipelineStateWithDescriptor:error:"),
        .{ desc, &err },
    );
    try checkError(err);

    return pipeline_state;
}

/// Initialize a MTLTexture object for the given atlas.
fn initAtlasTexture(device: objc.Object, atlas: *const Atlas) !objc.Object {
    // Determine our pixel format
    const pixel_format: MTLPixelFormat = switch (atlas.format) {
        .greyscale => .r8unorm,
        .rgba => .bgra8unorm,
        else => @panic("unsupported atlas format for Metal texture"),
    };

    // Create our descriptor
    const desc = init: {
        const Class = objc.Class.getClass("MTLTextureDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };

    // Set our properties
    desc.setProperty("pixelFormat", @enumToInt(pixel_format));
    desc.setProperty("width", @intCast(c_ulong, atlas.size));
    desc.setProperty("height", @intCast(c_ulong, atlas.size));

    // Initialize
    const id = device.msgSend(
        ?*anyopaque,
        objc.sel("newTextureWithDescriptor:"),
        .{desc},
    ) orelse return error.MetalFailed;

    return objc.Object.fromId(id);
}

/// Deinitialize a metal resource (buffer, texture, etc.) and free the
/// memory associated with it.
fn deinitMTLResource(obj: objc.Object) void {
    obj.msgSend(void, objc.sel("setPurgeableState:"), .{@enumToInt(MTLPurgeableState.empty)});
    obj.msgSend(void, objc.sel("release"), .{});
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

/// https://developer.apple.com/documentation/metal/mtlvertexformat?language=objc
const MTLVertexFormat = enum(c_ulong) {
    uchar4 = 3,
    float2 = 29,
    int2 = 33,
    uint2 = 37,
    uchar = 45,
};

/// https://developer.apple.com/documentation/metal/mtlvertexstepfunction?language=objc
const MTLVertexStepFunction = enum(c_ulong) {
    constant = 0,
    per_vertex = 1,
    per_instance = 2,
};

/// https://developer.apple.com/documentation/metal/mtlpixelformat?language=objc
const MTLPixelFormat = enum(c_ulong) {
    r8unorm = 10,
    bgra8unorm = 80,
};

/// https://developer.apple.com/documentation/metal/mtlpurgeablestate?language=objc
const MTLPurgeableState = enum(c_ulong) {
    empty = 4,
};

/// https://developer.apple.com/documentation/metal/mtlblendfactor?language=objc
const MTLBlendFactor = enum(c_ulong) {
    zero = 0,
    one = 1,
    source_color = 2,
    one_minus_source_color = 3,
    source_alpha = 4,
    one_minus_source_alpha = 5,
    dest_color = 6,
    one_minus_dest_color = 7,
    dest_alpha = 8,
    one_minus_dest_alpha = 9,
    source_alpha_saturated = 10,
    blend_color = 11,
    one_minus_blend_color = 12,
    blend_alpha = 13,
    one_minus_blend_alpha = 14,
    source_1_color = 15,
    one_minus_source_1_color = 16,
    source_1_alpha = 17,
    one_minus_source_1_alpha = 18,
};

/// https://developer.apple.com/documentation/metal/mtlblendoperation?language=objc
const MTLBlendOperation = enum(c_ulong) {
    add = 0,
    subtract = 1,
    reverse_subtract = 2,
    min = 3,
    max = 4,
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

const MTLRegion = extern struct {
    origin: MTLOrigin,
    size: MTLSize,
};

const MTLOrigin = extern struct {
    x: c_ulong,
    y: c_ulong,
    z: c_ulong,
};

const MTLSize = extern struct {
    width: c_ulong,
    height: c_ulong,
    depth: c_ulong,
};

extern "c" fn MTLCreateSystemDefaultDevice() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(?*anyopaque) void;
