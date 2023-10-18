const ImguiWidget = @This();

const std = @import("std");
const assert = std.debug.assert;

const cimgui = @import("cimgui");
const c = @import("c.zig");
const gl = @import("../../renderer/opengl/main.zig");

const log = std.log.scoped(.gtk_imgui_widget);

/// Our OpenGL widget
gl_area: *c.GtkGLArea,

ig_ctx: *cimgui.c.ImGuiContext,

/// Our previous instant used to calculate delta time.
instant: ?std.time.Instant = null,

/// Initialize the widget. This must have a stable pointer for events.
pub fn init(self: *ImguiWidget) !void {
    // Each widget gets its own imgui context so we can have multiple
    // imgui views in the same application.
    const ig_ctx = cimgui.c.igCreateContext(null);
    errdefer cimgui.c.igDestroyContext(ig_ctx);
    cimgui.c.igSetCurrentContext(ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    io.BackendPlatformName = "ghostty_gtk";

    const gl_area = c.gtk_gl_area_new();

    // Signals
    _ = c.g_signal_connect_data(gl_area, "destroy", c.G_CALLBACK(&gtkDestroy), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gl_area, "realize", c.G_CALLBACK(&gtkRealize), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gl_area, "unrealize", c.G_CALLBACK(&gtkUnrealize), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gl_area, "render", c.G_CALLBACK(&gtkRender), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gl_area, "resize", c.G_CALLBACK(&gtkResize), self, null, c.G_CONNECT_DEFAULT);

    self.* = .{
        .gl_area = @ptrCast(gl_area),
        .ig_ctx = ig_ctx,
    };
}

/// Deinitialize the widget. This should ONLY be called if the widget gl_area
/// was never added to a parent. Otherwise, cleanup automatically happens
/// when the widget is destroyed and this should NOT be called.
pub fn deinit(self: *ImguiWidget) void {
    cimgui.c.igDestroyContext(self.ig_ctx);
}

/// Initialize the frame. Expects that the context is already current.
fn newFrame(self: *ImguiWidget) !void {
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();

    // Determine our delta time
    const now = try std.time.Instant.now();
    io.DeltaTime = if (self.instant) |prev| delta: {
        const since_ns = now.since(prev);
        const since_s: f32 = @floatFromInt(since_ns / std.time.ns_per_s);
        break :delta @max(0.00001, since_s);
    } else (1 / 60);
    self.instant = now;
}

fn gtkDestroy(v: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
    _ = v;
    log.debug("imgui widget destroy", .{});

    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    self.deinit();
}

fn gtkRealize(area: *c.GtkGLArea, ud: ?*anyopaque) callconv(.C) void {
    log.debug("gl surface realized", .{});

    // We need to make the context current so we can call GL functions.
    c.gtk_gl_area_make_current(area);
    if (c.gtk_gl_area_get_error(area)) |err| {
        log.err("surface failed to realize: {s}", .{err.*.message});
        return;
    }

    // realize means that our OpenGL context is ready, so we can now
    // initialize the ImgUI OpenGL backend for our context.
    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    cimgui.c.igSetCurrentContext(self.ig_ctx);
    cimgui.c.ImGui_ImplOpenGL3_Init(null);
}

fn gtkUnrealize(area: *c.GtkGLArea, ud: ?*anyopaque) callconv(.C) void {
    _ = area;
    log.debug("gl surface unrealized", .{});

    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    cimgui.c.igSetCurrentContext(self.ig_ctx);
    cimgui.c.ImGui_ImplOpenGL3_Shutdown();
}

fn gtkResize(area: *c.GtkGLArea, width: c.gint, height: c.gint, ud: ?*anyopaque) callconv(.C) void {
    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    const scale_factor = c.gtk_widget_get_scale_factor(@ptrCast(area));
    log.debug("gl resize width={} height={} scale={}", .{
        width,
        height,
        scale_factor,
    });

    io.DisplaySize = .{
        .x = @floatFromInt(@divFloor(width, scale_factor)),
        .y = @floatFromInt(@divFloor(height, scale_factor)),
    };
    io.DisplayFramebufferScale = .{
        .x = @floatFromInt(scale_factor),
        .y = @floatFromInt(scale_factor),
    };
}

fn gtkRender(area: *c.GtkGLArea, ctx: *c.GdkGLContext, ud: ?*anyopaque) callconv(.C) c.gboolean {
    _ = area;
    _ = ctx;
    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));

    // Setup our frame
    cimgui.c.igSetCurrentContext(self.ig_ctx);
    cimgui.c.ImGui_ImplOpenGL3_NewFrame();
    self.newFrame() catch |err| {
        log.err("failed to setup frame: {}", .{err});
        return 0;
    };
    cimgui.c.igNewFrame();

    // Build our UI
    var show: bool = true;
    cimgui.c.igShowDemoWindow(&show);

    // Render
    cimgui.c.igRender();

    // OpenGL final render
    gl.clearColor(0.45, 0.55, 0.60, 1.00);
    gl.clear(gl.c.GL_COLOR_BUFFER_BIT);
    cimgui.c.ImGui_ImplOpenGL3_RenderDrawData(cimgui.c.igGetDrawData());

    return 1;
}
