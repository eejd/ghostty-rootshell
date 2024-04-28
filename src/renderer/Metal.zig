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
const glslang = @import("glslang");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const math = @import("../math.zig");
const Surface = @import("../Surface.zig");
const link = @import("link.zig");
const fgMode = @import("cell.zig").fgMode;
const shadertoy = @import("shadertoy.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Terminal = terminal.Terminal;
const Health = renderer.Health;

const mtl = @import("metal/api.zig");
const mtl_buffer = @import("metal/buffer.zig");
const mtl_cell = @import("metal/cell.zig");
const mtl_image = @import("metal/image.zig");
const mtl_sampler = @import("metal/sampler.zig");
const mtl_shaders = @import("metal/shaders.zig");
const Image = mtl_image.Image;
const ImageMap = mtl_image.ImageMap;
const Shaders = mtl_shaders.Shaders;

const ImageBuffer = mtl_buffer.Buffer(mtl_shaders.Image);
const InstanceBuffer = mtl_buffer.Buffer(u16);

const ImagePlacementList = std.ArrayListUnmanaged(mtl_image.Placement);

// Get native API access on certain platforms so we can do more customization.
const glfwNative = glfw.Native(.{
    .cocoa = builtin.os.tag == .macos,
});

const log = std.log.scoped(.metal);

/// Allocator that can be used
alloc: std.mem.Allocator,

/// The configuration we need derived from the main config.
config: DerivedConfig,

/// The mailbox for communicating with the window.
surface_mailbox: apprt.surface.Mailbox,

/// Current font metrics defining our grid.
grid_metrics: font.face.Metrics,

/// Current screen size dimensions for this grid. This is set on the first
/// resize event, and is not immediately available.
screen_size: ?renderer.ScreenSize,

/// Explicit padding.
padding: renderer.Options.Padding,

/// True if the window is focused
focused: bool,

/// The actual foreground color. May differ from the config foreground color if
/// changed by a terminal application
foreground_color: terminal.color.RGB,

/// The actual background color. May differ from the config background color if
/// changed by a terminal application
background_color: terminal.color.RGB,

/// The actual cursor color. May differ from the config cursor color if changed
/// by a terminal application
cursor_color: ?terminal.color.RGB,

/// The current frame background color. This is only updated during
/// the updateFrame method.
current_background_color: terminal.color.RGB,

/// The current set of cells to render. This is rebuilt on every frame
/// but we keep this around so that we don't reallocate. Each set of
/// cells goes into a separate shader.
// cells_bg: std.ArrayListUnmanaged(mtl_shaders.CellBg),
// cells_text: std.ArrayListUnmanaged(mtl_shaders.CellText),
cells: mtl_cell.Contents,

/// The current GPU uniform values.
uniforms: mtl_shaders.Uniforms,

/// The font structures.
font_grid: *font.SharedGrid,
font_shaper: font.Shaper,

/// The images that we may render.
images: ImageMap = .{},
image_placements: ImagePlacementList = .{},
image_bg_end: u32 = 0,
image_text_end: u32 = 0,

/// Metal state
shaders: Shaders, // Compiled shaders

/// Metal objects
layer: objc.Object, // CAMetalLayer

/// Custom shader state. This is only set if we have custom shaders.
custom_shader_state: ?CustomShaderState = null,

/// Health of the last frame. Note that when we do double/triple buffering
/// this will have to be part of the frame state.
health: std.atomic.Value(Health) = .{ .raw = .healthy },

/// Our GPU state
gpu_state: GPUState,

/// State we need for the GPU that is shared between all frames.
pub const GPUState = struct {
    // The count of buffers we use for double/triple buffering. If
    // this is one then we don't do any double+ buffering at all. This
    // is comptime because there isn't a good reason to change this at
    // runtime and there is a lot of complexity to support it. For comptime,
    // this is useful for debugging.
    const BufferCount = 3;

    /// The frame data, the current frame index, and the semaphore protecting
    /// the frame data. This is used to implement double/triple/etc. buffering.
    frames: [BufferCount]FrameState,
    frame_index: std.math.IntFittingRange(0, BufferCount - 1) = 0,
    frame_sema: std.Thread.Semaphore = .{ .permits = BufferCount },

    device: objc.Object, // MTLDevice
    queue: objc.Object, // MTLCommandQueue

    /// This buffer is written exactly once so we can use it globally.
    instance: InstanceBuffer, // MTLBuffer

    pub fn init() !GPUState {
        const device = objc.Object.fromId(mtl.MTLCreateSystemDefaultDevice());
        const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
        errdefer queue.msgSend(void, objc.sel("release"), .{});

        var instance = try InstanceBuffer.initFill(device, &.{
            0, 1, 3, // Top-left triangle
            1, 2, 3, // Bottom-right triangle
        });
        errdefer instance.deinit();

        var result: GPUState = .{
            .device = device,
            .queue = queue,
            .instance = instance,
            .frames = undefined,
        };

        // Initialize all of our frame state.
        for (&result.frames) |*frame| {
            frame.* = try FrameState.init(result.device);
        }

        return result;
    }

    pub fn deinit(self: *GPUState) void {
        // Wait for all of our inflight draws to complete so that
        // we can cleanly deinit our GPU state.
        for (0..BufferCount) |_| self.frame_sema.wait();
        for (&self.frames) |*frame| frame.deinit();
        self.instance.deinit();
        self.queue.msgSend(void, objc.sel("release"), .{});
    }

    /// Get the next frame state to draw to. This will wait on the
    /// semaphore to ensure that the frame is available. This must
    /// always be paired with a call to releaseFrame.
    pub fn nextFrame(self: *GPUState) *FrameState {
        self.frame_sema.wait();
        errdefer self.frame_sema.post();
        self.frame_index = (self.frame_index + 1) % BufferCount;
        return &self.frames[self.frame_index];
    }

    /// This should be called when the frame has completed drawing.
    pub fn releaseFrame(self: *GPUState) void {
        self.frame_sema.post();
    }
};

/// State we need duplicated for every frame. Any state that could be
/// in a data race between the GPU and CPU while a frame is being
/// drawn should be in this struct.
///
/// While a draw is in-process, we "lock" the state (via a semaphore)
/// and prevent the CPU from updating the state until Metal reports
/// that the frame is complete.
///
/// This is used to implement double/triple buffering.
pub const FrameState = struct {
    uniforms: UniformBuffer,
    cells: CellTextBuffer,
    cells_bg: CellBgBuffer,

    greyscale: objc.Object, // MTLTexture
    greyscale_modified: usize = 0,
    color: objc.Object, // MTLTexture
    color_modified: usize = 0,

    /// A buffer containing the uniform data.
    const UniformBuffer = mtl_buffer.Buffer(mtl_shaders.Uniforms);
    const CellBgBuffer = mtl_buffer.Buffer(mtl_shaders.CellBg);
    const CellTextBuffer = mtl_buffer.Buffer(mtl_shaders.CellText);

    pub fn init(device: objc.Object) !FrameState {
        // Uniform buffer contains exactly 1 uniform struct. The
        // uniform data will be undefined so this must be set before
        // a frame is drawn.
        var uniforms = try UniformBuffer.init(device, 1);
        errdefer uniforms.deinit();

        // Create the buffers for our vertex data. The preallocation size
        // is likely too small but our first frame update will resize it.
        var cells = try CellTextBuffer.init(device, 10 * 10);
        errdefer cells.deinit();
        var cells_bg = try CellBgBuffer.init(device, 10 * 10);
        errdefer cells_bg.deinit();

        // Initialize our textures for our font atlas.
        const greyscale = try initAtlasTexture(device, &.{
            .data = undefined,
            .size = 8,
            .format = .greyscale,
        });
        errdefer deinitMTLResource(greyscale);
        const color = try initAtlasTexture(device, &.{
            .data = undefined,
            .size = 8,
            .format = .rgba,
        });
        errdefer deinitMTLResource(color);

        return .{
            .uniforms = uniforms,
            .cells = cells,
            .cells_bg = cells_bg,
            .greyscale = greyscale,
            .color = color,
        };
    }

    pub fn deinit(self: *FrameState) void {
        self.uniforms.deinit();
        self.cells.deinit();
        self.cells_bg.deinit();
        deinitMTLResource(self.greyscale);
        deinitMTLResource(self.color);
    }
};

pub const CustomShaderState = struct {
    /// The screen texture that we render the terminal to. If we don't have
    /// custom shaders, we render directly to the drawable.
    screen_texture: objc.Object, // MTLTexture
    sampler: mtl_sampler.Sampler,
    uniforms: mtl_shaders.PostUniforms,
    /// The first time a frame was drawn. This is used to update the time
    /// uniform.
    first_frame_time: std.time.Instant,
    /// The last time a frame was drawn. This is used to update the time
    /// uniform.
    last_frame_time: std.time.Instant,

    pub fn deinit(self: *CustomShaderState) void {
        deinitMTLResource(self.screen_texture);
        self.sampler.deinit();
    }
};

/// The configuration for this renderer that is derived from the main
/// configuration. This must be exported so that we don't need to
/// pass around Config pointers which makes memory management a pain.
pub const DerivedConfig = struct {
    arena: ArenaAllocator,

    font_thicken: bool,
    font_features: std.ArrayListUnmanaged([:0]const u8),
    font_styles: font.CodepointResolver.StyleStatus,
    cursor_color: ?terminal.color.RGB,
    cursor_opacity: f64,
    cursor_text: ?terminal.color.RGB,
    background: terminal.color.RGB,
    background_opacity: f64,
    foreground: terminal.color.RGB,
    selection_background: ?terminal.color.RGB,
    selection_foreground: ?terminal.color.RGB,
    invert_selection_fg_bg: bool,
    min_contrast: f32,
    custom_shaders: std.ArrayListUnmanaged([:0]const u8),
    links: link.Set,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Copy our shaders
        const custom_shaders = try config.@"custom-shader".value.list.clone(alloc);

        // Copy our font features
        const font_features = try config.@"font-feature".list.clone(alloc);

        // Get our font styles
        var font_styles = font.CodepointResolver.StyleStatus.initFill(true);
        font_styles.set(.bold, config.@"font-style-bold" != .false);
        font_styles.set(.italic, config.@"font-style-italic" != .false);
        font_styles.set(.bold_italic, config.@"font-style-bold-italic" != .false);

        // Our link configs
        const links = try link.Set.fromConfig(
            alloc,
            config.link.links.items,
        );

        return .{
            .background_opacity = @max(0, @min(1, config.@"background-opacity")),
            .font_thicken = config.@"font-thicken",
            .font_features = font_features,
            .font_styles = font_styles,

            .cursor_color = if (config.@"cursor-color") |col|
                col.toTerminalRGB()
            else
                null,

            .cursor_text = if (config.@"cursor-text") |txt|
                txt.toTerminalRGB()
            else
                null,

            .cursor_opacity = @max(0, @min(1, config.@"cursor-opacity")),

            .background = config.background.toTerminalRGB(),
            .foreground = config.foreground.toTerminalRGB(),
            .invert_selection_fg_bg = config.@"selection-invert-fg-bg",
            .min_contrast = @floatCast(config.@"minimum-contrast"),

            .selection_background = if (config.@"selection-background") |bg|
                bg.toTerminalRGB()
            else
                null,

            .selection_foreground = if (config.@"selection-foreground") |bg|
                bg.toTerminalRGB()
            else
                null,

            .custom_shaders = custom_shaders,
            .links = links,

            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        const alloc = self.arena.allocator();
        self.links.deinit(alloc);
        self.arena.deinit();
    }
};

/// Returns the hints that we want for this
pub fn glfwWindowHints(config: *const configpkg.Config) glfw.Window.Hints {
    return .{
        .client_api = .no_api,
        .transparent_framebuffer = config.@"background-opacity" < 1,
    };
}

/// This is called early right after window creation to setup our
/// window surface as necessary.
pub fn surfaceInit(surface: *apprt.Surface) !void {
    _ = surface;

    // We don't do anything else here because we want to set everything
    // else up during actual initialization.
}

pub fn init(alloc: Allocator, options: renderer.Options) !Metal {
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const ViewInfo = struct {
        view: objc.Object,
        scaleFactor: f64,
    };

    // Get the metadata about our underlying view that we'll be rendering to.
    const info: ViewInfo = switch (apprt.runtime) {
        apprt.glfw => info: {
            // Everything in glfw is window-oriented so we grab the backing
            // window, then derive everything from that.
            const nswindow = objc.Object.fromId(glfwNative.getCocoaWindow(
                options.rt_surface.window,
            ).?);

            const contentView = objc.Object.fromId(
                nswindow.getProperty(?*anyopaque, "contentView").?,
            );
            const scaleFactor = nswindow.getProperty(
                macos.graphics.c.CGFloat,
                "backingScaleFactor",
            );

            break :info .{
                .view = contentView,
                .scaleFactor = scaleFactor,
            };
        },

        apprt.embedded => .{
            .scaleFactor = @floatCast(options.rt_surface.content_scale.x),
            .view = switch (options.rt_surface.platform) {
                .macos => |v| v.nsview,
                .ios => |v| v.uiview,
            },
        },

        else => @compileError("unsupported apprt for metal"),
    };

    // Initialize our metal stuff
    var gpu_state = try GPUState.init();
    errdefer gpu_state.deinit();

    // Get our CAMetalLayer
    const layer = switch (builtin.os.tag) {
        .macos => layer: {
            const CAMetalLayer = objc.getClass("CAMetalLayer").?;
            break :layer CAMetalLayer.msgSend(objc.Object, objc.sel("layer"), .{});
        },

        // iOS is always layer-backed so we don't need to do anything here.
        .ios => info.view.getProperty(objc.Object, "layer"),

        else => @compileError("unsupported target for Metal"),
    };
    layer.setProperty("device", gpu_state.device.value);
    layer.setProperty("opaque", options.config.background_opacity >= 1);
    layer.setProperty("displaySyncEnabled", false); // disable v-sync

    // Make our view layer-backed with our Metal layer. On iOS views are
    // always layer backed so we don't need to do this. But on iOS the
    // caller MUST be sure to set the layerClass to CAMetalLayer.
    if (comptime builtin.os.tag == .macos) {
        info.view.setProperty("layer", layer.value);
        info.view.setProperty("wantsLayer", true);

        // The layer gravity is set to top-left so that when we resize
        // the view, the contents aren't stretched before a redraw.
        layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);
    }

    // Ensure that our metal layer has a content scale set to match the
    // scale factor of the window. This avoids magnification issues leading
    // to blurry rendering.
    layer.setProperty("contentsScale", info.scaleFactor);

    // Create the font shaper. We initially create a shaper that can support
    // a width of 160 which is a common width for modern screens to help
    // avoid allocations later.
    var font_shaper = try font.Shaper.init(alloc, .{
        .features = options.config.font_features.items,
    });
    errdefer font_shaper.deinit();

    // Load our custom shaders
    const custom_shaders: []const [:0]const u8 = shadertoy.loadFromFiles(
        arena_alloc,
        options.config.custom_shaders.items,
        .msl,
    ) catch |err| err: {
        log.warn("error loading custom shaders err={}", .{err});
        break :err &.{};
    };

    // If we have custom shaders then setup our state
    var custom_shader_state: ?CustomShaderState = state: {
        if (custom_shaders.len == 0) break :state null;

        // Build our sampler for our texture
        var sampler = try mtl_sampler.Sampler.init(gpu_state.device);
        errdefer sampler.deinit();

        break :state .{
            // Resolution and screen texture will be fixed up by first
            // call to setScreenSize. This happens before any draw call.
            .screen_texture = undefined,
            .sampler = sampler,
            .uniforms = .{
                .resolution = .{ 0, 0, 1 },
                .time = 1,
                .time_delta = 1,
                .frame_rate = 1,
                .frame = 1,
                .channel_time = [1][4]f32{.{ 0, 0, 0, 0 }} ** 4,
                .channel_resolution = [1][4]f32{.{ 0, 0, 0, 0 }} ** 4,
                .mouse = .{ 0, 0, 0, 0 },
                .date = .{ 0, 0, 0, 0 },
                .sample_rate = 1,
            },

            .first_frame_time = try std.time.Instant.now(),
            .last_frame_time = try std.time.Instant.now(),
        };
    };
    errdefer if (custom_shader_state) |*state| state.deinit();

    // Initialize our shaders
    var shaders = try Shaders.init(alloc, gpu_state.device, custom_shaders);
    errdefer shaders.deinit(alloc);

    // Initialize all the data that requires a critical font section.
    const font_critical: struct {
        metrics: font.Metrics,
    } = font_critical: {
        const grid = options.font_grid;
        grid.lock.lockShared();
        defer grid.lock.unlockShared();
        break :font_critical .{
            .metrics = grid.metrics,
        };
    };

    const cells = try mtl_cell.Contents.init(alloc);
    errdefer cells.deinit(alloc);

    return Metal{
        .alloc = alloc,
        .config = options.config,
        .surface_mailbox = options.surface_mailbox,
        .grid_metrics = font_critical.metrics,
        .screen_size = null,
        .padding = options.padding,
        .focused = true,
        .foreground_color = options.config.foreground,
        .background_color = options.config.background,
        .cursor_color = options.config.cursor_color,
        .current_background_color = options.config.background,

        // Render state
        .cells = cells,
        .uniforms = .{
            .projection_matrix = undefined,
            .cell_size = undefined,
            .min_contrast = options.config.min_contrast,
        },

        // Fonts
        .font_grid = options.font_grid,
        .font_shaper = font_shaper,

        // Shaders
        .shaders = shaders,

        // Metal stuff
        .layer = layer,
        .custom_shader_state = custom_shader_state,
        .gpu_state = gpu_state,
    };
}

pub fn deinit(self: *Metal) void {
    self.gpu_state.deinit();

    self.cells.deinit(self.alloc);

    self.font_shaper.deinit();

    self.config.deinit();

    {
        var it = self.images.iterator();
        while (it.next()) |kv| kv.value_ptr.image.deinit(self.alloc);
        self.images.deinit(self.alloc);
    }
    self.image_placements.deinit(self.alloc);

    if (self.custom_shader_state) |*state| state.deinit();

    self.shaders.deinit(self.alloc);

    self.* = undefined;
}

/// This is called just prior to spinning up the renderer thread for
/// final main thread setup requirements.
pub fn finalizeSurfaceInit(self: *Metal, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;

    // Metal doesn't have to do anything here. OpenGL has to do things
    // like release the context but Metal doesn't have anything like that.
}

/// Callback called by renderer.Thread when it begins.
pub fn threadEnter(self: *const Metal, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;

    // Metal requires no per-thread state.
}

/// Callback called by renderer.Thread when it exits.
pub fn threadExit(self: *const Metal) void {
    _ = self;

    // Metal requires no per-thread state.
}

/// True if our renderer has animations so that a higher frequency
/// timer is used.
pub fn hasAnimations(self: *const Metal) bool {
    return self.custom_shader_state != null;
}

/// Returns the grid size for a given screen size. This is safe to call
/// on any thread.
fn gridSize(self: *Metal) ?renderer.GridSize {
    const screen_size = self.screen_size orelse return null;
    return renderer.GridSize.init(
        screen_size.subPadding(self.padding.explicit),
        .{
            .width = self.grid_metrics.cell_width,
            .height = self.grid_metrics.cell_height,
        },
    );
}

/// Callback when the focus changes for the terminal this is rendering.
///
/// Must be called on the render thread.
pub fn setFocus(self: *Metal, focus: bool) !void {
    self.focused = focus;
}

/// Set the new font size.
///
/// Must be called on the render thread.
pub fn setFontGrid(self: *Metal, grid: *font.SharedGrid) void {
    // Update our grid
    self.font_grid = grid;

    // Update all our textures so that they sync on the next frame.
    // We can modify this without a lock because the GPU does not
    // touch this data.
    for (&self.gpu_state.frames) |*frame| {
        frame.greyscale_modified = 0;
        frame.color_modified = 0;
    }

    // Get our metrics from the grid. This doesn't require a lock because
    // the metrics are never recalculated.
    const metrics = grid.metrics;
    self.grid_metrics = metrics;

    // Update our uniforms
    self.uniforms = .{
        .projection_matrix = self.uniforms.projection_matrix,
        .cell_size = .{
            @floatFromInt(metrics.cell_width),
            @floatFromInt(metrics.cell_height),
        },
        .min_contrast = self.uniforms.min_contrast,
    };
}

/// Update the frame data.
pub fn updateFrame(
    self: *Metal,
    surface: *apprt.Surface,
    state: *renderer.State,
    cursor_blink_visible: bool,
) !void {
    _ = surface;

    // Data we extract out of the critical area.
    const Critical = struct {
        bg: terminal.color.RGB,
        screen: terminal.Screen,
        mouse: renderer.State.Mouse,
        preedit: ?renderer.State.Preedit,
        cursor_style: ?renderer.CursorStyle,
        color_palette: terminal.color.Palette,
    };

    // Update all our data as tightly as possible within the mutex.
    var critical: Critical = critical: {
        state.mutex.lock();
        defer state.mutex.unlock();

        // If we're in a synchronized output state, we pause all rendering.
        if (state.terminal.modes.get(.synchronized_output)) {
            log.debug("synchronized output started, skipping render", .{});
            return;
        }

        // Swap bg/fg if the terminal is reversed
        const bg = self.background_color;
        const fg = self.foreground_color;
        defer {
            self.background_color = bg;
            self.foreground_color = fg;
        }
        if (state.terminal.modes.get(.reverse_colors)) {
            self.background_color = fg;
            self.foreground_color = bg;
        }

        // We used to share terminal state, but we've since learned through
        // analysis that it is faster to copy the terminal state than to
        // hold the lock while rebuilding GPU cells.
        var screen_copy = try state.terminal.screen.clone(
            self.alloc,
            .{ .viewport = .{} },
            null,
        );
        errdefer screen_copy.deinit();

        // Whether to draw our cursor or not.
        const cursor_style = renderer.cursorStyle(
            state,
            self.focused,
            cursor_blink_visible,
        );

        // Get our preedit state
        const preedit: ?renderer.State.Preedit = preedit: {
            if (cursor_style == null) break :preedit null;
            const p = state.preedit orelse break :preedit null;
            break :preedit try p.clone(self.alloc);
        };
        errdefer if (preedit) |p| p.deinit(self.alloc);

        // If we have Kitty graphics data, we enter a SLOW SLOW SLOW path.
        // We only do this if the Kitty image state is dirty meaning only if
        // it changes.
        if (state.terminal.screen.kitty_images.dirty) {
            try self.prepKittyGraphics(state.terminal);
        }

        break :critical .{
            .bg = self.background_color,
            .screen = screen_copy,
            .mouse = state.mouse,
            .preedit = preedit,
            .cursor_style = cursor_style,
            .color_palette = state.terminal.color_palette.colors,
        };
    };
    defer {
        critical.screen.deinit();
        if (critical.preedit) |p| p.deinit(self.alloc);
    }

    // Build our GPU cells (OLD)
    // try self.rebuildCells(
    //     &critical.screen,
    //     critical.mouse,
    //     critical.preedit,
    //     critical.cursor_style,
    //     &critical.color_palette,
    // );

    // Build our GPU cells
    try self.rebuildCells2(
        &critical.screen,
        critical.mouse,
        critical.preedit,
        critical.cursor_style,
        &critical.color_palette,
    );

    // Update our background color
    self.current_background_color = critical.bg;

    // Go through our images and see if we need to setup any textures.
    {
        var image_it = self.images.iterator();
        while (image_it.next()) |kv| {
            switch (kv.value_ptr.image) {
                .ready => {},

                .pending_grey_alpha,
                .pending_rgb,
                .pending_rgba,
                .replace_grey_alpha,
                .replace_rgb,
                .replace_rgba,
                => try kv.value_ptr.image.upload(self.alloc, self.gpu_state.device),

                .unload_pending,
                .unload_replace,
                .unload_ready,
                => {
                    kv.value_ptr.image.deinit(self.alloc);
                    self.images.removeByPtr(kv.key_ptr);
                },
            }
        }
    }
}

/// Draw the frame to the screen.
pub fn drawFrame(self: *Metal, surface: *apprt.Surface) !void {
    _ = surface;

    // Wait for a frame to be available.
    const frame = self.gpu_state.nextFrame();
    errdefer self.gpu_state.releaseFrame();
    // log.debug("drawing frame index={}", .{self.gpu_state.frame_index});

    // Setup our frame data
    const cells_bg = self.cells.bgCells();
    const cells_fg = self.cells.fgCells();
    try frame.uniforms.sync(self.gpu_state.device, &.{self.uniforms});
    try frame.cells_bg.sync(self.gpu_state.device, cells_bg);
    try frame.cells.sync(self.gpu_state.device, cells_fg);

    // If we have custom shaders, update the animation time.
    if (self.custom_shader_state) |*state| {
        const now = std.time.Instant.now() catch state.first_frame_time;
        const since_ns: f32 = @floatFromInt(now.since(state.first_frame_time));
        const delta_ns: f32 = @floatFromInt(now.since(state.last_frame_time));
        state.uniforms.time = since_ns / std.time.ns_per_s;
        state.uniforms.time_delta = delta_ns / std.time.ns_per_s;
        state.last_frame_time = now;
    }

    // @autoreleasepool {}
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    // Get our drawable (CAMetalDrawable)
    const drawable = self.layer.msgSend(objc.Object, objc.sel("nextDrawable"), .{});

    // Get our screen texture. If we don't have a dedicated screen texture
    // then we just use the drawable texture.
    const screen_texture = if (self.custom_shader_state) |state|
        state.screen_texture
    else tex: {
        const texture = drawable.msgSend(objc.c.id, objc.sel("texture"), .{});
        break :tex objc.Object.fromId(texture);
    };

    // If our font atlas changed, sync the texture data
    texture: {
        const modified = self.font_grid.atlas_greyscale.modified.load(.monotonic);
        if (modified <= frame.greyscale_modified) break :texture;
        self.font_grid.lock.lockShared();
        defer self.font_grid.lock.unlockShared();
        frame.greyscale_modified = self.font_grid.atlas_greyscale.modified.load(.monotonic);
        try syncAtlasTexture(self.gpu_state.device, &self.font_grid.atlas_greyscale, &frame.greyscale);
    }
    texture: {
        const modified = self.font_grid.atlas_color.modified.load(.monotonic);
        if (modified <= frame.color_modified) break :texture;
        self.font_grid.lock.lockShared();
        defer self.font_grid.lock.unlockShared();
        frame.color_modified = self.font_grid.atlas_color.modified.load(.monotonic);
        try syncAtlasTexture(self.gpu_state.device, &self.font_grid.atlas_color, &frame.color);
    }

    // Command buffer (MTLCommandBuffer)
    const buffer = self.gpu_state.queue.msgSend(objc.Object, objc.sel("commandBuffer"), .{});

    {
        // MTLRenderPassDescriptor
        const desc = desc: {
            const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor").?;
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

                // Texture is a property of CAMetalDrawable but if you run
                // Ghostty in XCode in debug mode it returns a CaptureMTLDrawable
                // which ironically doesn't implement CAMetalDrawable as a
                // property so we just send a message.
                //const texture = drawable.msgSend(objc.c.id, objc.sel("texture"), .{});
                attachment.setProperty("loadAction", @intFromEnum(mtl.MTLLoadAction.clear));
                attachment.setProperty("storeAction", @intFromEnum(mtl.MTLStoreAction.store));
                attachment.setProperty("texture", screen_texture.value);
                attachment.setProperty("clearColor", mtl.MTLClearColor{
                    .red = @as(f32, @floatFromInt(self.current_background_color.r)) / 255,
                    .green = @as(f32, @floatFromInt(self.current_background_color.g)) / 255,
                    .blue = @as(f32, @floatFromInt(self.current_background_color.b)) / 255,
                    .alpha = self.config.background_opacity,
                });
            }

            break :desc desc;
        };

        // MTLRenderCommandEncoder
        const encoder = buffer.msgSend(
            objc.Object,
            objc.sel("renderCommandEncoderWithDescriptor:"),
            .{desc.value},
        );
        defer encoder.msgSend(void, objc.sel("endEncoding"), .{});

        // Draw background images first
        try self.drawImagePlacements(encoder, self.image_placements.items[0..self.image_bg_end]);

        // Then draw background cells
        try self.drawCellBgs(encoder, frame, cells_bg.len);

        // Then draw images under text
        try self.drawImagePlacements(encoder, self.image_placements.items[self.image_bg_end..self.image_text_end]);

        // Then draw fg cells
        try self.drawCellFgs(encoder, frame, cells_fg.len);

        // Then draw remaining images
        try self.drawImagePlacements(encoder, self.image_placements.items[self.image_text_end..]);
    }

    // If we have custom shaders AND we have a screen texture, then we
    // render the custom shaders.
    if (self.custom_shader_state) |state| {
        // MTLRenderPassDescriptor
        const desc = desc: {
            const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor").?;
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

                // Texture is a property of CAMetalDrawable but if you run
                // Ghostty in XCode in debug mode it returns a CaptureMTLDrawable
                // which ironically doesn't implement CAMetalDrawable as a
                // property so we just send a message.
                const texture = drawable.msgSend(objc.c.id, objc.sel("texture"), .{});
                attachment.setProperty("loadAction", @intFromEnum(mtl.MTLLoadAction.clear));
                attachment.setProperty("storeAction", @intFromEnum(mtl.MTLStoreAction.store));
                attachment.setProperty("texture", texture);
                attachment.setProperty("clearColor", mtl.MTLClearColor{
                    .red = 0,
                    .green = 0,
                    .blue = 0,
                    .alpha = 1,
                });
            }

            break :desc desc;
        };

        // MTLRenderCommandEncoder
        const encoder = buffer.msgSend(
            objc.Object,
            objc.sel("renderCommandEncoderWithDescriptor:"),
            .{desc.value},
        );
        defer encoder.msgSend(void, objc.sel("endEncoding"), .{});

        for (self.shaders.post_pipelines) |pipeline| {
            try self.drawPostShader(encoder, pipeline, &state);
        }
    }

    buffer.msgSend(void, objc.sel("presentDrawable:"), .{drawable.value});

    // Create our block to register for completion updates. This is used
    // so we can detect failures. The block is deallocated by the objC
    // runtime on success.
    const block = try CompletionBlock.init(.{ .self = self }, &bufferCompleted);
    errdefer block.deinit();
    buffer.msgSend(void, objc.sel("addCompletedHandler:"), .{block.context});

    buffer.msgSend(void, objc.sel("commit"), .{});
}

/// This is the block type used for the addCompletedHandler call.back.
const CompletionBlock = objc.Block(struct { self: *Metal }, .{
    objc.c.id, // MTLCommandBuffer
}, void);

/// This is the callback called by the CompletionBlock invocation for
/// addCompletedHandler.
///
/// Note: this is USUALLY called on a separate thread because the renderer
/// thread and the Apple event loop threads are usually different. Therefore,
/// we need to be mindful of thread safety here.
fn bufferCompleted(
    block: *const CompletionBlock.Context,
    buffer_id: objc.c.id,
) callconv(.C) void {
    const self = block.self;
    const buffer = objc.Object.fromId(buffer_id);

    // Get our command buffer status. If it is anything other than error
    // then we don't care and just return right away. We're looking for
    // errors so that we can log them.
    const status = buffer.getProperty(mtl.MTLCommandBufferStatus, "status");
    const health: Health = switch (status) {
        .@"error" => .unhealthy,
        else => .healthy,
    };

    // If our health value hasn't changed, then we do nothing. We don't
    // do a cmpxchg here because strict atomicity isn't important.
    if (self.health.load(.seq_cst) != health) {
        self.health.store(health, .seq_cst);

        // Our health value changed, so we notify the surface so that it
        // can do something about it.
        _ = self.surface_mailbox.push(.{
            .renderer_health = health,
        }, .{ .forever = {} });
    }

    // Always release our semaphore
    self.gpu_state.releaseFrame();
}

fn drawPostShader(
    self: *Metal,
    encoder: objc.Object,
    pipeline: objc.Object,
    state: *const CustomShaderState,
) !void {
    _ = self;

    // Use our custom shader pipeline
    encoder.msgSend(
        void,
        objc.sel("setRenderPipelineState:"),
        .{pipeline.value},
    );

    // Set our sampler
    encoder.msgSend(
        void,
        objc.sel("setFragmentSamplerState:atIndex:"),
        .{ state.sampler.sampler.value, @as(c_ulong, 0) },
    );

    // Set our uniforms
    encoder.msgSend(
        void,
        objc.sel("setFragmentBytes:length:atIndex:"),
        .{
            @as(*const anyopaque, @ptrCast(&state.uniforms)),
            @as(c_ulong, @sizeOf(@TypeOf(state.uniforms))),
            @as(c_ulong, 0),
        },
    );

    // Screen texture
    encoder.msgSend(
        void,
        objc.sel("setFragmentTexture:atIndex:"),
        .{
            state.screen_texture.value,
            @as(c_ulong, 0),
        },
    );

    // Draw!
    encoder.msgSend(
        void,
        objc.sel("drawPrimitives:vertexStart:vertexCount:"),
        .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle_strip),
            @as(c_ulong, 0),
            @as(c_ulong, 4),
        },
    );
}

fn drawImagePlacements(
    self: *Metal,
    encoder: objc.Object,
    placements: []const mtl_image.Placement,
) !void {
    if (placements.len == 0) return;

    // Use our image shader pipeline
    encoder.msgSend(
        void,
        objc.sel("setRenderPipelineState:"),
        .{self.shaders.image_pipeline.value},
    );

    // Set our uniform, which is the only shared buffer
    encoder.msgSend(
        void,
        objc.sel("setVertexBytes:length:atIndex:"),
        .{
            @as(*const anyopaque, @ptrCast(&self.uniforms)),
            @as(c_ulong, @sizeOf(@TypeOf(self.uniforms))),
            @as(c_ulong, 1),
        },
    );

    for (placements) |placement| {
        try self.drawImagePlacement(encoder, placement);
    }
}

fn drawImagePlacement(
    self: *Metal,
    encoder: objc.Object,
    p: mtl_image.Placement,
) !void {
    // Look up the image
    const image = self.images.get(p.image_id) orelse {
        log.warn("image not found for placement image_id={}", .{p.image_id});
        return;
    };

    // Get the texture
    const texture = switch (image.image) {
        .ready => |t| t,
        else => {
            log.warn("image not ready for placement image_id={}", .{p.image_id});
            return;
        },
    };

    // Create our vertex buffer, which is always exactly one item.
    // future(mitchellh): we can group rendering multiple instances of a single image
    const Buffer = mtl_buffer.Buffer(mtl_shaders.Image);
    var buf = try Buffer.initFill(self.gpu_state.device, &.{.{
        .grid_pos = .{
            @as(f32, @floatFromInt(p.x)),
            @as(f32, @floatFromInt(p.y)),
        },

        .cell_offset = .{
            @as(f32, @floatFromInt(p.cell_offset_x)),
            @as(f32, @floatFromInt(p.cell_offset_y)),
        },

        .source_rect = .{
            @as(f32, @floatFromInt(p.source_x)),
            @as(f32, @floatFromInt(p.source_y)),
            @as(f32, @floatFromInt(p.source_width)),
            @as(f32, @floatFromInt(p.source_height)),
        },

        .dest_size = .{
            @as(f32, @floatFromInt(p.width)),
            @as(f32, @floatFromInt(p.height)),
        },
    }});
    defer buf.deinit();

    // Set our buffer
    encoder.msgSend(
        void,
        objc.sel("setVertexBuffer:offset:atIndex:"),
        .{ buf.buffer.value, @as(c_ulong, 0), @as(c_ulong, 0) },
    );

    // Set our texture
    encoder.msgSend(
        void,
        objc.sel("setVertexTexture:atIndex:"),
        .{
            texture.value,
            @as(c_ulong, 0),
        },
    );
    encoder.msgSend(
        void,
        objc.sel("setFragmentTexture:atIndex:"),
        .{
            texture.value,
            @as(c_ulong, 0),
        },
    );

    // Draw!
    encoder.msgSend(
        void,
        objc.sel("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:"),
        .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, 6),
            @intFromEnum(mtl.MTLIndexType.uint16),
            self.gpu_state.instance.buffer.value,
            @as(c_ulong, 0),
            @as(c_ulong, 1),
        },
    );

    // log.debug("drawImagePlacement: {}", .{p});
}

/// Draw the cell backgrounds.
fn drawCellBgs(
    self: *Metal,
    encoder: objc.Object,
    frame: *const FrameState,
    len: usize,
) !void {
    // This triggers an assertion in the Metal API if we try to draw
    // with an instance count of 0 so just bail.
    if (len == 0) return;

    // Use our shader pipeline
    encoder.msgSend(
        void,
        objc.sel("setRenderPipelineState:"),
        .{self.shaders.cell_bg_pipeline.value},
    );

    // Set our buffers
    encoder.msgSend(
        void,
        objc.sel("setVertexBuffer:offset:atIndex:"),
        .{ frame.cells_bg.buffer.value, @as(c_ulong, 0), @as(c_ulong, 0) },
    );
    encoder.msgSend(
        void,
        objc.sel("setVertexBuffer:offset:atIndex:"),
        .{ frame.uniforms.buffer.value, @as(c_ulong, 0), @as(c_ulong, 1) },
    );

    encoder.msgSend(
        void,
        objc.sel("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:"),
        .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, 6),
            @intFromEnum(mtl.MTLIndexType.uint16),
            self.gpu_state.instance.buffer.value,
            @as(c_ulong, 0),
            @as(c_ulong, len),
        },
    );
}

/// Draw the cell foregrounds using the text shader.
fn drawCellFgs(
    self: *Metal,
    encoder: objc.Object,
    frame: *const FrameState,
    len: usize,
) !void {
    // This triggers an assertion in the Metal API if we try to draw
    // with an instance count of 0 so just bail.
    if (len == 0) return;

    // Use our shader pipeline
    encoder.msgSend(
        void,
        objc.sel("setRenderPipelineState:"),
        .{self.shaders.cell_text_pipeline.value},
    );

    // Set our buffers
    encoder.msgSend(
        void,
        objc.sel("setVertexBuffer:offset:atIndex:"),
        .{ frame.cells.buffer.value, @as(c_ulong, 0), @as(c_ulong, 0) },
    );
    encoder.msgSend(
        void,
        objc.sel("setVertexBuffer:offset:atIndex:"),
        .{ frame.uniforms.buffer.value, @as(c_ulong, 0), @as(c_ulong, 1) },
    );
    encoder.msgSend(
        void,
        objc.sel("setFragmentTexture:atIndex:"),
        .{
            frame.greyscale.value,
            @as(c_ulong, 0),
        },
    );
    encoder.msgSend(
        void,
        objc.sel("setFragmentTexture:atIndex:"),
        .{
            frame.color.value,
            @as(c_ulong, 1),
        },
    );

    encoder.msgSend(
        void,
        objc.sel("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:"),
        .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, 6),
            @intFromEnum(mtl.MTLIndexType.uint16),
            self.gpu_state.instance.buffer.value,
            @as(c_ulong, 0),
            @as(c_ulong, len),
        },
    );
}

/// This goes through the Kitty graphic placements and accumulates the
/// placements we need to render on our viewport. It also ensures that
/// the visible images are loaded on the GPU.
fn prepKittyGraphics(
    self: *Metal,
    t: *terminal.Terminal,
) !void {
    const storage = &t.screen.kitty_images;
    defer storage.dirty = false;

    // We always clear our previous placements no matter what because
    // we rebuild them from scratch.
    self.image_placements.clearRetainingCapacity();

    // Go through our known images and if there are any that are no longer
    // in use then mark them to be freed.
    //
    // This never conflicts with the below because a placement can't
    // reference an image that doesn't exist.
    {
        var it = self.images.iterator();
        while (it.next()) |kv| {
            if (storage.imageById(kv.key_ptr.*) == null) {
                kv.value_ptr.image.markForUnload();
            }
        }
    }

    // The top-left and bottom-right corners of our viewport in screen
    // points. This lets us determine offsets and containment of placements.
    const top = t.screen.pages.getTopLeft(.viewport);
    const bot = t.screen.pages.getBottomRight(.viewport).?;

    // Go through the placements and ensure the image is loaded on the GPU.
    var it = storage.placements.iterator();
    while (it.next()) |kv| {
        // Find the image in storage
        const p = kv.value_ptr;
        const image = storage.imageById(kv.key_ptr.image_id) orelse {
            log.warn(
                "missing image for placement, ignoring image_id={}",
                .{kv.key_ptr.image_id},
            );
            continue;
        };

        // If the selection isn't within our viewport then skip it.
        const rect = p.rect(image, t);
        if (bot.before(rect.top_left)) continue;
        if (rect.bottom_right.before(top)) continue;

        // If the top left is outside the viewport we need to calc an offset
        // so that we render (0, 0) with some offset for the texture.
        const offset_y: u32 = if (rect.top_left.before(top)) offset_y: {
            const vp_y = t.screen.pages.pointFromPin(.screen, top).?.screen.y;
            const img_y = t.screen.pages.pointFromPin(.screen, rect.top_left).?.screen.y;
            const offset_cells = vp_y - img_y;
            const offset_pixels = offset_cells * self.grid_metrics.cell_height;
            break :offset_y @intCast(offset_pixels);
        } else 0;

        // We need to prep this image for upload if it isn't in the cache OR
        // it is in the cache but the transmit time doesn't match meaning this
        // image is different.
        const gop = try self.images.getOrPut(self.alloc, kv.key_ptr.image_id);
        if (!gop.found_existing or
            gop.value_ptr.transmit_time.order(image.transmit_time) != .eq)
        {
            // Copy the data into the pending state.
            const data = try self.alloc.dupe(u8, image.data);
            errdefer self.alloc.free(data);

            // Store it in the map
            const pending: Image.Pending = .{
                .width = image.width,
                .height = image.height,
                .data = data.ptr,
            };

            const new_image: Image = switch (image.format) {
                .grey_alpha => .{ .pending_grey_alpha = pending },
                .rgb => .{ .pending_rgb = pending },
                .rgba => .{ .pending_rgba = pending },
                .png => unreachable, // should be decoded by now
            };

            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .image = new_image,
                    .transmit_time = undefined,
                };
            } else {
                try gop.value_ptr.image.markForReplace(
                    self.alloc,
                    new_image,
                );
            }

            gop.value_ptr.transmit_time = image.transmit_time;
        }

        // Convert our screen point to a viewport point
        const viewport: terminal.point.Point = t.screen.pages.pointFromPin(
            .viewport,
            p.pin.*,
        ) orelse .{ .viewport = .{} };

        // Calculate the source rectangle
        const source_x = @min(image.width, p.source_x);
        const source_y = @min(image.height, p.source_y + offset_y);
        const source_width = if (p.source_width > 0)
            @min(image.width - source_x, p.source_width)
        else
            image.width;
        const source_height = if (p.source_height > 0)
            @min(image.height, p.source_height)
        else
            image.height -| offset_y;

        // Calculate the width/height of our image.
        const dest_width = if (p.columns > 0) p.columns * self.grid_metrics.cell_width else source_width;
        const dest_height = if (p.rows > 0) p.rows * self.grid_metrics.cell_height else source_height;

        // Accumulate the placement
        if (image.width > 0 and image.height > 0) {
            try self.image_placements.append(self.alloc, .{
                .image_id = kv.key_ptr.image_id,
                .x = @intCast(p.pin.x),
                .y = @intCast(viewport.viewport.y),
                .z = p.z,
                .width = dest_width,
                .height = dest_height,
                .cell_offset_x = p.x_offset,
                .cell_offset_y = p.y_offset,
                .source_x = source_x,
                .source_y = source_y,
                .source_width = source_width,
                .source_height = source_height,
            });
        }
    }

    // Sort the placements by their Z value.
    std.mem.sortUnstable(
        mtl_image.Placement,
        self.image_placements.items,
        {},
        struct {
            fn lessThan(
                ctx: void,
                lhs: mtl_image.Placement,
                rhs: mtl_image.Placement,
            ) bool {
                _ = ctx;
                return lhs.z < rhs.z or (lhs.z == rhs.z and lhs.image_id < rhs.image_id);
            }
        }.lessThan,
    );

    // Find our indices
    self.image_bg_end = 0;
    self.image_text_end = 0;
    const bg_limit = std.math.minInt(i32) / 2;
    for (self.image_placements.items, 0..) |p, i| {
        if (self.image_bg_end == 0 and p.z >= bg_limit) {
            self.image_bg_end = @intCast(i);
        }
        if (self.image_text_end == 0 and p.z >= 0) {
            self.image_text_end = @intCast(i);
        }
    }
    if (self.image_text_end == 0) {
        self.image_text_end = @intCast(self.image_placements.items.len);
    }
}

/// Update the configuration.
pub fn changeConfig(self: *Metal, config: *DerivedConfig) !void {
    // We always redo the font shaper in case font features changed. We
    // could check to see if there was an actual config change but this is
    // easier and rare enough to not cause performance issues.
    {
        var font_shaper = try font.Shaper.init(self.alloc, .{
            .features = config.font_features.items,
        });
        errdefer font_shaper.deinit();
        self.font_shaper.deinit();
        self.font_shaper = font_shaper;
    }

    // Set our new minimum contrast
    self.uniforms.min_contrast = config.min_contrast;

    // Set our new colors
    self.background_color = config.background;
    self.foreground_color = config.foreground;
    self.cursor_color = config.cursor_color;

    self.config.deinit();
    self.config = config.*;
}

/// Resize the screen.
pub fn setScreenSize(
    self: *Metal,
    dim: renderer.ScreenSize,
    pad: renderer.Padding,
) !void {
    // Store our sizes
    self.screen_size = dim;
    self.padding.explicit = pad;

    // Recalculate the rows/columns. This can't fail since we just set
    // the screen size above.
    const grid_size = self.gridSize().?;

    // Determine if we need to pad the window. For "auto" padding, we take
    // the leftover amounts on the right/bottom that don't fit a full grid cell
    // and we split them equal across all boundaries.
    const padding = if (self.padding.balance)
        renderer.Padding.balanced(
            dim,
            grid_size,
            .{
                .width = self.grid_metrics.cell_width,
                .height = self.grid_metrics.cell_height,
            },
        )
    else
        self.padding.explicit;
    const padded_dim = dim.subPadding(padding);

    // Set the size of the drawable surface to the bounds
    self.layer.setProperty("drawableSize", macos.graphics.Size{
        .width = @floatFromInt(dim.width),
        .height = @floatFromInt(dim.height),
    });

    // Setup our uniforms
    const old = self.uniforms;
    self.uniforms = .{
        .projection_matrix = math.ortho2d(
            -1 * @as(f32, @floatFromInt(padding.left)),
            @floatFromInt(padded_dim.width + padding.right),
            @floatFromInt(padded_dim.height + padding.bottom),
            -1 * @as(f32, @floatFromInt(padding.top)),
        ),
        .cell_size = .{
            @floatFromInt(self.grid_metrics.cell_width),
            @floatFromInt(self.grid_metrics.cell_height),
        },
        .min_contrast = old.min_contrast,
    };

    // Reset our cell contents.
    try self.cells.resize(self.alloc, grid_size);

    // If we have custom shaders then we update the state
    if (self.custom_shader_state) |*state| {
        // Only free our previous texture if this isn't our first
        // time setting the custom shader state.
        if (state.uniforms.resolution[0] > 0) {
            deinitMTLResource(state.screen_texture);
        }

        state.uniforms.resolution = .{
            @floatFromInt(dim.width),
            @floatFromInt(dim.height),
            1,
        };

        state.screen_texture = screen_texture: {
            // This texture is the size of our drawable but supports being a
            // render target AND reading so that the custom shaders can read from it.
            const desc = init: {
                const Class = objc.getClass("MTLTextureDescriptor").?;
                const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
                const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
                break :init id_init;
            };
            desc.setProperty("pixelFormat", @intFromEnum(mtl.MTLPixelFormat.bgra8unorm));
            desc.setProperty("width", @as(c_ulong, @intCast(dim.width)));
            desc.setProperty("height", @as(c_ulong, @intCast(dim.height)));
            desc.setProperty(
                "usage",
                @intFromEnum(mtl.MTLTextureUsage.render_target) |
                    @intFromEnum(mtl.MTLTextureUsage.shader_read) |
                    @intFromEnum(mtl.MTLTextureUsage.shader_write),
            );

            // If we fail to create the texture, then we just don't have a screen
            // texture and our custom shaders won't run.
            const id = self.gpu_state.device.msgSend(
                ?*anyopaque,
                objc.sel("newTextureWithDescriptor:"),
                .{desc},
            ) orelse return error.MetalFailed;

            break :screen_texture objc.Object.fromId(id);
        };
    }

    log.debug("screen size screen={} grid={}, cell_width={} cell_height={}", .{ dim, grid_size, self.grid_metrics.cell_width, self.grid_metrics.cell_height });
}

/// Sync all the CPU cells with the GPU state (but still on the CPU here).
/// This builds all our "GPUCells" on this struct, but doesn't send them
/// down to the GPU yet.
fn rebuildCells(
    self: *Metal,
    screen: *terminal.Screen,
    mouse: renderer.State.Mouse,
    preedit: ?renderer.State.Preedit,
    cursor_style_: ?renderer.CursorStyle,
    color_palette: *const terminal.color.Palette,
) !void {
    const rows_usize: usize = @intCast(screen.pages.rows);
    const cols_usize: usize = @intCast(screen.pages.cols);

    // Bg cells at most will need space for the visible screen size
    self.cells_bg.clearRetainingCapacity();
    try self.cells_bg.ensureTotalCapacity(
        self.alloc,
        rows_usize * cols_usize,
    );

    // Over-allocate just to ensure we don't allocate again during loops.
    self.cells_text.clearRetainingCapacity();
    try self.cells_text.ensureTotalCapacity(
        self.alloc,

        // * 3 for glyph + underline + strikethrough for each cell
        // + 1 for cursor
        (rows_usize * cols_usize * 3) + 1,
    );

    // Create an arena for all our temporary allocations while rebuilding
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Create our match set for the links.
    var link_match_set: link.MatchSet = if (mouse.point) |mouse_pt| try self.config.links.matchSet(
        arena_alloc,
        screen,
        mouse_pt,
        mouse.mods,
    ) else .{};

    // Determine our x/y range for preedit. We don't want to render anything
    // here because we will render the preedit separately.
    const preedit_range: ?struct {
        y: terminal.size.CellCountInt,
        x: [2]terminal.size.CellCountInt,
        cp_offset: usize,
    } = if (preedit) |preedit_v| preedit: {
        const range = preedit_v.range(screen.cursor.x, screen.pages.cols - 1);
        break :preedit .{
            .y = screen.cursor.y,
            .x = .{ range.start, range.end },
            .cp_offset = range.cp_offset,
        };
    } else null;

    // This is the cell that has [mode == .fg] and is underneath our cursor.
    // We keep track of it so that we can invert the colors so the character
    // remains visible.
    var cursor_cell: ?mtl_shaders.CellText = null;

    // Build each cell
    var row_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
    var y: terminal.size.CellCountInt = 0;
    while (row_it.next()) |row| {
        defer y += 1;

        // True if this is the row with our cursor. There are a lot of conditions
        // here because the reasons we need to know this are primarily to invert.
        //
        //   - If we aren't drawing the cursor then we don't need to change our rendering.
        //   - If the cursor is not visible, then we don't need to change rendering.
        //   - If the cursor style is not a box, then we don't need to change
        //     rendering because it'll never fully overlap a glyph.
        //   - If the viewport is not at the bottom, then we don't need to
        //     change rendering because the cursor is not visible.
        //     (NOTE: this may not be fully correct, we may be scrolled
        //     slightly up and the cursor may be visible)
        //   - If this y doesn't match our cursor y then we don't need to
        //     change rendering.
        //
        const cursor_row = if (cursor_style_) |cursor_style|
            cursor_style == .block and
                screen.viewportIsBottom() and
                y == screen.cursor.y
        else
            false;

        // True if we want to do font shaping around the cursor. We want to
        // do font shaping as long as the cursor is enabled.
        const shape_cursor = screen.viewportIsBottom() and
            y == screen.cursor.y;

        // If this is the row with our cursor, then we may have to modify
        // the cell with the cursor.
        const start_i: usize = self.cells_text.items.len;
        defer if (cursor_row) {
            // If we're on a wide spacer tail, then we want to look for
            // the previous cell.
            const screen_cell = row.cells(.all)[screen.cursor.x];
            const x = screen.cursor.x - @intFromBool(screen_cell.wide == .spacer_tail);
            for (self.cells_text.items[start_i..]) |cell| {
                if (cell.grid_pos[0] == x and
                    (cell.mode == .fg or cell.mode == .fg_color))
                {
                    cursor_cell = cell;
                    break;
                }
            }
        };

        // We need to get this row's selection if there is one for proper
        // run splitting.
        const row_selection = sel: {
            const sel = screen.selection orelse break :sel null;
            const pin = screen.pages.pin(.{ .viewport = .{ .y = y } }) orelse
                break :sel null;
            break :sel sel.containedRow(screen, pin) orelse null;
        };

        // Split our row into runs and shape each one.
        var iter = self.font_shaper.runIterator(
            self.font_grid,
            screen,
            row,
            row_selection,
            if (shape_cursor) screen.cursor.x else null,
        );
        while (try iter.next(self.alloc)) |run| {
            for (try self.font_shaper.shape(run)) |shaper_cell| {
                // If this cell falls within our preedit range then we skip it.
                // We do this so we don't have conflicting data on the same
                // cell.
                if (preedit_range) |range| {
                    if (range.y == y and
                        shaper_cell.x >= range.x[0] and
                        shaper_cell.x <= range.x[1])
                    {
                        continue;
                    }
                }

                // It this cell is within our hint range then we need to
                // underline it.
                const cell: terminal.Pin = cell: {
                    var copy = row;
                    copy.x = shaper_cell.x;
                    break :cell copy;
                };

                if (self.updateCell(
                    screen,
                    cell,
                    if (link_match_set.orderedContains(screen, cell))
                        .single
                    else
                        null,
                    color_palette,
                    shaper_cell,
                    run,
                    shaper_cell.x,
                    y,
                )) |update| {
                    assert(update);
                } else |err| {
                    log.warn("error building cell, will be invalid x={} y={}, err={}", .{
                        shaper_cell.x,
                        y,
                        err,
                    });
                }
            }
        }
    }

    // Add the cursor at the end so that it overlays everything. If we have
    // a cursor cell then we invert the colors on that and add it in so
    // that we can always see it.
    if (cursor_style_) |cursor_style| cursor_style: {
        // If we have a preedit, we try to render the preedit text on top
        // of the cursor.
        if (preedit) |preedit_v| {
            const range = preedit_range.?;
            var x = range.x[0];
            for (preedit_v.codepoints[range.cp_offset..]) |cp| {
                self.addPreeditCell(cp, x, range.y) catch |err| {
                    log.warn("error building preedit cell, will be invalid x={} y={}, err={}", .{
                        x,
                        range.y,
                        err,
                    });
                };

                x += if (cp.wide) 2 else 1;
            }

            // Preedit hides the cursor
            break :cursor_style;
        }

        _ = self.addCursor(screen, cursor_style);
        if (cursor_cell) |*cell| {
            if (cell.mode == .fg) {
                cell.color = if (self.config.cursor_text) |txt|
                    .{ txt.r, txt.g, txt.b, 255 }
                else
                    .{ self.background_color.r, self.background_color.g, self.background_color.b, 255 };
            }

            self.cells_text.appendAssumeCapacity(cell.*);
        }
    }
}

/// Convert the terminal state to GPU cells stored in CPU memory. These
/// are then synced to the GPU in the next frame. This only updates CPU
/// memory and doesn't touch the GPU.
fn rebuildCells2(
    self: *Metal,
    screen: *terminal.Screen,
    mouse: renderer.State.Mouse,
    preedit: ?renderer.State.Preedit,
    cursor_style_: ?renderer.CursorStyle,
    color_palette: *const terminal.color.Palette,
) !void {
    // TODO: cursor_cell
    // TODO: cursor_Row

    // Create an arena for all our temporary allocations while rebuilding
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Create our match set for the links.
    var link_match_set: link.MatchSet = if (mouse.point) |mouse_pt| try self.config.links.matchSet(
        arena_alloc,
        screen,
        mouse_pt,
        mouse.mods,
    ) else .{};

    // Determine our x/y range for preedit. We don't want to render anything
    // here because we will render the preedit separately.
    const preedit_range: ?struct {
        y: terminal.size.CellCountInt,
        x: [2]terminal.size.CellCountInt,
        cp_offset: usize,
    } = if (preedit) |preedit_v| preedit: {
        const range = preedit_v.range(screen.cursor.x, screen.pages.cols - 1);
        break :preedit .{
            .y = screen.cursor.y,
            .x = .{ range.start, range.end },
            .cp_offset = range.cp_offset,
        };
    } else null;

    // Go row-by-row to build the cells. We go row by row because we do
    // font shaping by row. In the future, we will also do dirty tracking
    // by row.
    var row_it = screen.pages.rowIterator(.left_up, .{ .viewport = .{} }, null);
    var y: terminal.size.CellCountInt = screen.pages.rows;
    while (row_it.next()) |row| {
        y = y - 1;

        // If we're rebuilding a row, then we always clear the cells
        self.cells.clear(y);

        // True if we want to do font shaping around the cursor. We want to
        // do font shaping as long as the cursor is enabled.
        const shape_cursor = screen.viewportIsBottom() and
            y == screen.cursor.y;

        // We need to get this row's selection if there is one for proper
        // run splitting.
        const row_selection = sel: {
            const sel = screen.selection orelse break :sel null;
            const pin = screen.pages.pin(.{ .viewport = .{ .y = y } }) orelse
                break :sel null;
            break :sel sel.containedRow(screen, pin) orelse null;
        };

        // Split our row into runs and shape each one.
        var iter = self.font_shaper.runIterator(
            self.font_grid,
            screen,
            row,
            row_selection,
            if (shape_cursor) screen.cursor.x else null,
        );
        while (try iter.next(self.alloc)) |run| {
            for (try self.font_shaper.shape(run)) |shaper_cell| {
                const coord: terminal.Coordinate = .{
                    .x = shaper_cell.x,
                    .y = y,
                };

                // If this cell falls within our preedit range then we skip it.
                // We do this so we don't have conflicting data on the same
                // cell.
                if (preedit_range) |range| {
                    if (range.y == coord.y and
                        coord.x >= range.x[0] and
                        coord.x <= range.x[1])
                    {
                        continue;
                    }
                }

                // It this cell is within our hint range then we need to
                // underline it.
                const cell: terminal.Pin = cell: {
                    var copy = row;
                    copy.x = coord.x;
                    break :cell copy;
                };

                if (self.updateCell2(
                    screen,
                    cell,
                    if (link_match_set.orderedContains(screen, cell))
                        .single
                    else
                        null,
                    color_palette,
                    shaper_cell,
                    run,
                    coord,
                )) |update| {
                    assert(update);
                } else |err| {
                    log.warn("error building cell, will be invalid x={} y={}, err={}", .{
                        coord.x,
                        coord.y,
                        err,
                    });
                }
            }
        }
    }

    // Setup our cursor rendering information.
    cursor: {
        // If we have no cursor style then we don't render the cursor.
        const style = cursor_style_ orelse {
            self.cells.setCursor(null);
            break :cursor;
        };

        // Prepare the cursor cell contents.
        self.addCursor2(screen, style);
    }

    // If we have a preedit, we try to render the preedit text on top
    // of the cursor.
    // if (preedit) |preedit_v| {
    //     const range = preedit_range.?;
    //     var x = range.x[0];
    //     for (preedit_v.codepoints[range.cp_offset..]) |cp| {
    //         self.addPreeditCell(cp, x, range.y) catch |err| {
    //             log.warn("error building preedit cell, will be invalid x={} y={}, err={}", .{
    //                 x,
    //                 range.y,
    //                 err,
    //             });
    //         };
    //
    //         x += if (cp.wide) 2 else 1;
    //     }
    //
    //     // Preedit hides the cursor
    //     break :cursor_style;
    // }

    // if (cursor_cell) |*cell| {
    //     if (cell.mode == .fg) {
    //         cell.color = if (self.config.cursor_text) |txt|
    //             .{ txt.r, txt.g, txt.b, 255 }
    //         else
    //             .{ self.background_color.r, self.background_color.g, self.background_color.b, 255 };
    //     }
    //
    //     self.cells_text.appendAssumeCapacity(cell.*);
    // }
}

fn updateCell2(
    self: *Metal,
    screen: *const terminal.Screen,
    cell_pin: terminal.Pin,
    cell_underline: ?terminal.Attribute.Underline,
    palette: *const terminal.color.Palette,
    shaper_cell: font.shape.Cell,
    shaper_run: font.shape.TextRun,
    coord: terminal.Coordinate,
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

    // True if this cell is selected
    const selected: bool = if (screen.selection) |sel|
        sel.contains(screen, cell_pin)
    else
        false;

    const rac = cell_pin.rowAndCell();
    const cell = rac.cell;
    const style = cell_pin.style(cell);
    const underline = cell_underline orelse style.flags.underline;

    // The colors for the cell.
    const colors: BgFg = colors: {
        // The normal cell result
        const cell_res: BgFg = if (!style.flags.inverse) .{
            // In normal mode, background and fg match the cell. We
            // un-optionalize the fg by defaulting to our fg color.
            .bg = style.bg(cell, palette),
            .fg = style.fg(palette) orelse self.foreground_color,
        } else .{
            // In inverted mode, the background MUST be set to something
            // (is never null) so it is either the fg or default fg. The
            // fg is either the bg or default background.
            .bg = style.fg(palette) orelse self.foreground_color,
            .fg = style.bg(cell, palette) orelse self.background_color,
        };

        // If we are selected, we our colors are just inverted fg/bg
        const selection_res: ?BgFg = if (selected) .{
            .bg = if (self.config.invert_selection_fg_bg)
                cell_res.fg
            else
                self.config.selection_background orelse self.foreground_color,
            .fg = if (self.config.invert_selection_fg_bg)
                cell_res.bg orelse self.background_color
            else
                self.config.selection_foreground orelse self.background_color,
        } else null;

        // If the cell is "invisible" then we just make fg = bg so that
        // the cell is transparent but still copy-able.
        const res: BgFg = selection_res orelse cell_res;
        if (style.flags.invisible) {
            break :colors BgFg{
                .bg = res.bg,
                .fg = res.bg orelse self.background_color,
            };
        }

        break :colors res;
    };

    // Alpha multiplier
    const alpha: u8 = if (style.flags.faint) 175 else 255;

    // If the cell has a background, we always draw it.
    const bg: [4]u8 = if (colors.bg) |rgb| bg: {
        // Determine our background alpha. If we have transparency configured
        // then this is dynamic depending on some situations. This is all
        // in an attempt to make transparency look the best for various
        // situations. See inline comments.
        const bg_alpha: u8 = bg_alpha: {
            const default: u8 = 255;

            if (self.config.background_opacity >= 1) break :bg_alpha default;

            // If we're selected, we do not apply background opacity
            if (selected) break :bg_alpha default;

            // If we're reversed, do not apply background opacity
            if (style.flags.inverse) break :bg_alpha default;

            // If we have a background and its not the default background
            // then we apply background opacity
            if (style.bg(cell, palette) != null and !rgb.eql(self.background_color)) {
                break :bg_alpha default;
            }

            // We apply background opacity.
            var bg_alpha: f64 = @floatFromInt(default);
            bg_alpha *= self.config.background_opacity;
            bg_alpha = @ceil(bg_alpha);
            break :bg_alpha @intFromFloat(bg_alpha);
        };

        try self.cells.set(self.alloc, .bg, .{
            .mode = .rgb,
            .grid_pos = .{ @intCast(coord.x), @intCast(coord.y) },
            .cell_width = cell.gridWidth(),
            .color = .{ rgb.r, rgb.g, rgb.b, bg_alpha },
        });

        break :bg .{ rgb.r, rgb.g, rgb.b, bg_alpha };
    } else .{
        self.current_background_color.r,
        self.current_background_color.g,
        self.current_background_color.b,
        @intFromFloat(@max(0, @min(255, @round(self.config.background_opacity * 255)))),
    };

    // If the cell has a character, draw it
    if (cell.hasText()) fg: {
        // Render
        const render = try self.font_grid.renderGlyph(
            self.alloc,
            shaper_run.font_index,
            shaper_cell.glyph_index orelse break :fg,
            .{
                .grid_metrics = self.grid_metrics,
                .thicken = self.config.font_thicken,
            },
        );

        const mode: mtl_shaders.CellText.Mode = switch (try fgMode(
            render.presentation,
            cell_pin,
        )) {
            .normal => .fg,
            .color => .fg_color,
            .constrained => .fg_constrained,
        };

        try self.cells.set(self.alloc, .text, .{
            .mode = mode,
            .grid_pos = .{ @intCast(coord.x), @intCast(coord.y) },
            .cell_width = cell.gridWidth(),
            .color = .{ colors.fg.r, colors.fg.g, colors.fg.b, alpha },
            .bg_color = bg,
            .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
            .glyph_size = .{ render.glyph.width, render.glyph.height },
            .glyph_offset = .{
                render.glyph.offset_x + shaper_cell.x_offset,
                render.glyph.offset_y + shaper_cell.y_offset,
            },
        });
    }

    if (underline != .none) {
        const sprite: font.Sprite = switch (underline) {
            .none => unreachable,
            .single => .underline,
            .double => .underline_double,
            .dotted => .underline_dotted,
            .dashed => .underline_dashed,
            .curly => .underline_curly,
        };

        const render = try self.font_grid.renderGlyph(
            self.alloc,
            font.sprite_index,
            @intFromEnum(sprite),
            .{
                .cell_width = if (cell.wide == .wide) 2 else 1,
                .grid_metrics = self.grid_metrics,
            },
        );

        const color = style.underlineColor(palette) orelse colors.fg;

        try self.cells.set(self.alloc, .underline, .{
            .mode = .fg,
            .grid_pos = .{ @intCast(coord.x), @intCast(coord.y) },
            .cell_width = cell.gridWidth(),
            .color = .{ color.r, color.g, color.b, alpha },
            .bg_color = bg,
            .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
            .glyph_size = .{ render.glyph.width, render.glyph.height },
            .glyph_offset = .{ render.glyph.offset_x, render.glyph.offset_y },
        });
    }

    if (style.flags.strikethrough) {
        const render = try self.font_grid.renderGlyph(
            self.alloc,
            font.sprite_index,
            @intFromEnum(font.Sprite.strikethrough),
            .{
                .cell_width = if (cell.wide == .wide) 2 else 1,
                .grid_metrics = self.grid_metrics,
            },
        );

        try self.cells.set(self.alloc, .strikethrough, .{
            .mode = .fg,
            .grid_pos = .{ @intCast(coord.x), @intCast(coord.y) },
            .cell_width = cell.gridWidth(),
            .color = .{ colors.fg.r, colors.fg.g, colors.fg.b, alpha },
            .bg_color = bg,
            .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
            .glyph_size = .{ render.glyph.width, render.glyph.height },
            .glyph_offset = .{ render.glyph.offset_x, render.glyph.offset_y },
        });
    }

    return true;
}

fn updateCell(
    self: *Metal,
    screen: *const terminal.Screen,
    cell_pin: terminal.Pin,
    cell_underline: ?terminal.Attribute.Underline,
    palette: *const terminal.color.Palette,
    shaper_cell: font.shape.Cell,
    shaper_run: font.shape.TextRun,
    x: terminal.size.CellCountInt,
    y: terminal.size.CellCountInt,
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

    // True if this cell is selected
    const selected: bool = if (screen.selection) |sel|
        sel.contains(screen, cell_pin)
    else
        false;

    const rac = cell_pin.rowAndCell();
    const cell = rac.cell;
    const style = cell_pin.style(cell);
    const underline = cell_underline orelse style.flags.underline;

    // The colors for the cell.
    const colors: BgFg = colors: {
        // The normal cell result
        const cell_res: BgFg = if (!style.flags.inverse) .{
            // In normal mode, background and fg match the cell. We
            // un-optionalize the fg by defaulting to our fg color.
            .bg = style.bg(cell, palette),
            .fg = style.fg(palette) orelse self.foreground_color,
        } else .{
            // In inverted mode, the background MUST be set to something
            // (is never null) so it is either the fg or default fg. The
            // fg is either the bg or default background.
            .bg = style.fg(palette) orelse self.foreground_color,
            .fg = style.bg(cell, palette) orelse self.background_color,
        };

        // If we are selected, we our colors are just inverted fg/bg
        const selection_res: ?BgFg = if (selected) .{
            .bg = if (self.config.invert_selection_fg_bg)
                cell_res.fg
            else
                self.config.selection_background orelse self.foreground_color,
            .fg = if (self.config.invert_selection_fg_bg)
                cell_res.bg orelse self.background_color
            else
                self.config.selection_foreground orelse self.background_color,
        } else null;

        // If the cell is "invisible" then we just make fg = bg so that
        // the cell is transparent but still copy-able.
        const res: BgFg = selection_res orelse cell_res;
        if (style.flags.invisible) {
            break :colors BgFg{
                .bg = res.bg,
                .fg = res.bg orelse self.background_color,
            };
        }

        break :colors res;
    };

    // Alpha multiplier
    const alpha: u8 = if (style.flags.faint) 175 else 255;

    // If the cell has a background, we always draw it.
    const bg: [4]u8 = if (colors.bg) |rgb| bg: {
        // Determine our background alpha. If we have transparency configured
        // then this is dynamic depending on some situations. This is all
        // in an attempt to make transparency look the best for various
        // situations. See inline comments.
        const bg_alpha: u8 = bg_alpha: {
            const default: u8 = 255;

            if (self.config.background_opacity >= 1) break :bg_alpha default;

            // If we're selected, we do not apply background opacity
            if (selected) break :bg_alpha default;

            // If we're reversed, do not apply background opacity
            if (style.flags.inverse) break :bg_alpha default;

            // If we have a background and its not the default background
            // then we apply background opacity
            if (style.bg(cell, palette) != null and !rgb.eql(self.background_color)) {
                break :bg_alpha default;
            }

            // We apply background opacity.
            var bg_alpha: f64 = @floatFromInt(default);
            bg_alpha *= self.config.background_opacity;
            bg_alpha = @ceil(bg_alpha);
            break :bg_alpha @intFromFloat(bg_alpha);
        };

        self.cells_bg.appendAssumeCapacity(.{
            .mode = .rgb,
            .grid_pos = .{ x, y },
            .cell_width = cell.gridWidth(),
            .color = .{ rgb.r, rgb.g, rgb.b, bg_alpha },
        });

        break :bg .{ rgb.r, rgb.g, rgb.b, bg_alpha };
    } else .{
        self.current_background_color.r,
        self.current_background_color.g,
        self.current_background_color.b,
        @intFromFloat(@max(0, @min(255, @round(self.config.background_opacity * 255)))),
    };

    // If the cell has a character, draw it
    if (cell.hasText()) fg: {
        // Render
        const render = try self.font_grid.renderGlyph(
            self.alloc,
            shaper_run.font_index,
            shaper_cell.glyph_index orelse break :fg,
            .{
                .grid_metrics = self.grid_metrics,
                .thicken = self.config.font_thicken,
            },
        );

        const mode: mtl_shaders.CellText.Mode = switch (try fgMode(
            render.presentation,
            cell_pin,
        )) {
            .normal => .fg,
            .color => .fg_color,
            .constrained => .fg_constrained,
        };

        self.cells_text.appendAssumeCapacity(.{
            .mode = mode,
            .grid_pos = .{ x, y },
            .cell_width = cell.gridWidth(),
            .color = .{ colors.fg.r, colors.fg.g, colors.fg.b, alpha },
            .bg_color = bg,
            .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
            .glyph_size = .{ render.glyph.width, render.glyph.height },
            .glyph_offset = .{
                render.glyph.offset_x + shaper_cell.x_offset,
                render.glyph.offset_y + shaper_cell.y_offset,
            },
        });
    }

    if (underline != .none) {
        const sprite: font.Sprite = switch (underline) {
            .none => unreachable,
            .single => .underline,
            .double => .underline_double,
            .dotted => .underline_dotted,
            .dashed => .underline_dashed,
            .curly => .underline_curly,
        };

        const render = try self.font_grid.renderGlyph(
            self.alloc,
            font.sprite_index,
            @intFromEnum(sprite),
            .{
                .cell_width = if (cell.wide == .wide) 2 else 1,
                .grid_metrics = self.grid_metrics,
            },
        );

        const color = style.underlineColor(palette) orelse colors.fg;

        self.cells_text.appendAssumeCapacity(.{
            .mode = .fg,
            .grid_pos = .{ x, y },
            .cell_width = cell.gridWidth(),
            .color = .{ color.r, color.g, color.b, alpha },
            .bg_color = bg,
            .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
            .glyph_size = .{ render.glyph.width, render.glyph.height },
            .glyph_offset = .{ render.glyph.offset_x, render.glyph.offset_y },
        });
    }

    if (style.flags.strikethrough) {
        const render = try self.font_grid.renderGlyph(
            self.alloc,
            font.sprite_index,
            @intFromEnum(font.Sprite.strikethrough),
            .{
                .cell_width = if (cell.wide == .wide) 2 else 1,
                .grid_metrics = self.grid_metrics,
            },
        );

        self.cells_text.appendAssumeCapacity(.{
            .mode = .fg,
            .grid_pos = .{ x, y },
            .cell_width = cell.gridWidth(),
            .color = .{ colors.fg.r, colors.fg.g, colors.fg.b, alpha },
            .bg_color = bg,
            .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
            .glyph_size = .{ render.glyph.width, render.glyph.height },
            .glyph_offset = .{ render.glyph.offset_x, render.glyph.offset_y },
        });
    }

    return true;
}

fn addCursor2(
    self: *Metal,
    screen: *terminal.Screen,
    cursor_style: renderer.CursorStyle,
) void {
    // Add the cursor. We render the cursor over the wide character if
    // we're on the wide characer tail.
    const wide, const x = cell: {
        // The cursor goes over the screen cursor position.
        const cell = screen.cursor.page_cell;
        if (cell.wide != .spacer_tail or screen.cursor.x == 0)
            break :cell .{ cell.wide == .wide, screen.cursor.x };

        // If we're part of a wide character, we move the cursor back to
        // the actual character.
        const prev_cell = screen.cursorCellLeft(1);
        break :cell .{ prev_cell.wide == .wide, screen.cursor.x - 1 };
    };

    const color = self.cursor_color orelse self.foreground_color;
    const alpha: u8 = if (!self.focused) 255 else alpha: {
        const alpha = 255 * self.config.cursor_opacity;
        break :alpha @intFromFloat(@ceil(alpha));
    };

    const sprite: font.Sprite = switch (cursor_style) {
        .block => .cursor_rect,
        .block_hollow => .cursor_hollow_rect,
        .bar => .cursor_bar,
        .underline => .underline,
    };

    const render = self.font_grid.renderGlyph(
        self.alloc,
        font.sprite_index,
        @intFromEnum(sprite),
        .{
            .cell_width = if (wide) 2 else 1,
            .grid_metrics = self.grid_metrics,
        },
    ) catch |err| {
        log.warn("error rendering cursor glyph err={}", .{err});
        return;
    };

    self.cells.setCursor(.{
        .mode = .fg,
        .grid_pos = .{ x, screen.cursor.y },
        .cell_width = if (wide) 2 else 1,
        .color = .{ color.r, color.g, color.b, alpha },
        .bg_color = .{ 0, 0, 0, 0 },
        .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
        .glyph_size = .{ render.glyph.width, render.glyph.height },
        .glyph_offset = .{ render.glyph.offset_x, render.glyph.offset_y },
    });
}

fn addCursor(
    self: *Metal,
    screen: *terminal.Screen,
    cursor_style: renderer.CursorStyle,
) ?*const mtl_shaders.CellText {
    // Add the cursor. We render the cursor over the wide character if
    // we're on the wide characer tail.
    const wide, const x = cell: {
        // The cursor goes over the screen cursor position.
        const cell = screen.cursor.page_cell;
        if (cell.wide != .spacer_tail or screen.cursor.x == 0)
            break :cell .{ cell.wide == .wide, screen.cursor.x };

        // If we're part of a wide character, we move the cursor back to
        // the actual character.
        const prev_cell = screen.cursorCellLeft(1);
        break :cell .{ prev_cell.wide == .wide, screen.cursor.x - 1 };
    };

    const color = self.cursor_color orelse self.foreground_color;
    const alpha: u8 = if (!self.focused) 255 else alpha: {
        const alpha = 255 * self.config.cursor_opacity;
        break :alpha @intFromFloat(@ceil(alpha));
    };

    const sprite: font.Sprite = switch (cursor_style) {
        .block => .cursor_rect,
        .block_hollow => .cursor_hollow_rect,
        .bar => .cursor_bar,
        .underline => .underline,
    };

    const render = self.font_grid.renderGlyph(
        self.alloc,
        font.sprite_index,
        @intFromEnum(sprite),
        .{
            .cell_width = if (wide) 2 else 1,
            .grid_metrics = self.grid_metrics,
        },
    ) catch |err| {
        log.warn("error rendering cursor glyph err={}", .{err});
        return null;
    };

    self.cells_text.appendAssumeCapacity(.{
        .mode = .fg,
        .grid_pos = .{ x, screen.cursor.y },
        .cell_width = if (wide) 2 else 1,
        .color = .{ color.r, color.g, color.b, alpha },
        .bg_color = .{ 0, 0, 0, 0 },
        .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
        .glyph_size = .{ render.glyph.width, render.glyph.height },
        .glyph_offset = .{ render.glyph.offset_x, render.glyph.offset_y },
    });

    return &self.cells_text.items[self.cells_text.items.len - 1];
}

fn addPreeditCell(
    self: *Metal,
    cp: renderer.State.Preedit.Codepoint,
    x: terminal.size.CellCountInt,
    y: terminal.size.CellCountInt,
) !void {
    // Preedit is rendered inverted
    const bg = self.foreground_color;
    const fg = self.background_color;

    // Render the glyph for our preedit text
    const render_ = self.font_grid.renderCodepoint(
        self.alloc,
        @intCast(cp.codepoint),
        .regular,
        .text,
        .{ .grid_metrics = self.grid_metrics },
    ) catch |err| {
        log.warn("error rendering preedit glyph err={}", .{err});
        return;
    };
    const render = render_ orelse {
        log.warn("failed to find font for preedit codepoint={X}", .{cp.codepoint});
        return;
    };

    // Add our opaque background cell
    self.cells_bg.appendAssumeCapacity(.{
        .mode = .rgb,
        .grid_pos = .{ x, y },
        .cell_width = if (cp.wide) 2 else 1,
        .color = .{ bg.r, bg.g, bg.b, 255 },
    });

    // Add our text
    self.cells_text.appendAssumeCapacity(.{
        .mode = .fg,
        .grid_pos = .{ x, y },
        .cell_width = if (cp.wide) 2 else 1,
        .color = .{ fg.r, fg.g, fg.b, 255 },
        .bg_color = .{ bg.r, bg.g, bg.b, 255 },
        .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
        .glyph_size = .{ render.glyph.width, render.glyph.height },
        .glyph_offset = .{ render.glyph.offset_x, render.glyph.offset_y },
    });
}

/// Sync the atlas data to the given texture. This copies the bytes
/// associated with the atlas to the given texture. If the atlas no longer
/// fits into the texture, the texture will be resized.
fn syncAtlasTexture(device: objc.Object, atlas: *const font.Atlas, texture: *objc.Object) !void {
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
            mtl.MTLRegion{
                .origin = .{ .x = 0, .y = 0, .z = 0 },
                .size = .{
                    .width = @intCast(atlas.size),
                    .height = @intCast(atlas.size),
                    .depth = 1,
                },
            },
            @as(c_ulong, 0),
            @as(*const anyopaque, atlas.data.ptr),
            @as(c_ulong, atlas.format.depth() * atlas.size),
        },
    );
}

/// Initialize a MTLTexture object for the given atlas.
fn initAtlasTexture(device: objc.Object, atlas: *const font.Atlas) !objc.Object {
    // Determine our pixel format
    const pixel_format: mtl.MTLPixelFormat = switch (atlas.format) {
        .greyscale => .r8unorm,
        .rgba => .bgra8unorm,
        else => @panic("unsupported atlas format for Metal texture"),
    };

    // Create our descriptor
    const desc = init: {
        const Class = objc.getClass("MTLTextureDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };

    // Set our properties
    desc.setProperty("pixelFormat", @intFromEnum(pixel_format));
    desc.setProperty("width", @as(c_ulong, @intCast(atlas.size)));
    desc.setProperty("height", @as(c_ulong, @intCast(atlas.size)));

    // Xcode tells us that this texture should be shared mode on
    // aarch64. This configuration is not supported on x86_64 so
    // we only set it on aarch64.
    if (comptime builtin.target.cpu.arch == .aarch64) {
        desc.setProperty(
            "storageMode",
            @as(c_ulong, mtl.MTLResourceStorageModeShared),
        );
    }

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
    obj.msgSend(void, objc.sel("release"), .{});
}

test {
    _ = mtl_cell;
}
