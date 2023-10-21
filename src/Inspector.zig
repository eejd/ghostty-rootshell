//! The Inspector is a development tool to debug the terminal. This is
//! useful for terminal application developers as well as people potentially
//! debugging issues in Ghostty itself.
const Inspector = @This();

const cimgui = @import("cimgui");
const Surface = @import("Surface.zig");

/// The window names. These are used with docking so we need to have access.
const window_modes = "Modes";

show_modes_window: bool = true,

/// Setup the ImGui state. This requires an ImGui context to be set.
pub fn setup() void {
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();

    // Enable docking, which we use heavily for the UI.
    io.ConfigFlags |= cimgui.c.ImGuiConfigFlags_DockingEnable;

    // Our colorspace is sRGB.
    io.ConfigFlags |= cimgui.c.ImGuiConfigFlags_IsSRGB;

    // Disable the ini file to save layout
    io.IniFilename = null;
    io.LogFilename = null;

    // Use our own embedded font
    {
        // TODO: This will have to be recalculated for different screen DPIs.
        // This is currently hardcoded to a 2x content scale.
        const font_size = 16 * 2;

        const font_config: *cimgui.c.ImFontConfig = cimgui.c.ImFontConfig_ImFontConfig();
        defer cimgui.c.ImFontConfig_destroy(font_config);
        font_config.FontDataOwnedByAtlas = false;
        _ = cimgui.c.ImFontAtlas_AddFontFromMemoryTTF(
            io.Fonts,
            @constCast(@ptrCast(Surface.face_ttf)),
            Surface.face_ttf.len,
            font_size,
            font_config,
            null,
        );
    }
}

pub fn init() Inspector {
    return .{};
}

pub fn deinit(self: *Inspector) void {
    _ = self;
}

/// Render the frame.
pub fn render(self: *Inspector) void {
    const dock_id = cimgui.c.igDockSpaceOverViewport(
        cimgui.c.igGetMainViewport(),
        cimgui.c.ImGuiDockNodeFlags_None,
        null,
    );

    // Flip this boolean to true whenever you want to see the ImGui demo
    // window which can help you figure out how to use various ImGui widgets.
    if (false) {
        var show: bool = true;
        cimgui.c.igShowDemoWindow(&show);
    }

    self.renderModesWindow();

    // Setup our dock. We want all our main windows to be tabs in the main bar.
    cimgui.c.igDockBuilderDockWindow(window_modes, dock_id);
}

/// The modes window shows the currently active terminal modes and allows
/// users to toggle them on and off.
fn renderModesWindow(self: *Inspector) void {
    if (!self.show_modes_window) return;

    // Start our window. If we're collapsed we do nothing.
    defer cimgui.c.igEnd();
    if (!cimgui.c.igBegin(
        window_modes,
        &self.show_modes_window,
        cimgui.c.ImGuiWindowFlags_None,
    )) return;
}
