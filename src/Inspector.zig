//! The Inspector is a development tool to debug the terminal. This is
//! useful for terminal application developers as well as people potentially
//! debugging issues in Ghostty itself.
const Inspector = @This();

const cimgui = @import("cimgui");
const Surface = @import("Surface.zig");

/// Setup the ImGui state. This requires an ImGui context to be set.
pub fn setup() void {
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();

    // Enable docking, which we use heavily for the UI.
    io.ConfigFlags |= cimgui.c.ImGuiConfigFlags_DockingEnable;

    // Our colorspace is sRGB.
    io.ConfigFlags |= cimgui.c.ImGuiConfigFlags_IsSRGB;

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
    _ = self;

    _ = cimgui.c.igDockSpaceOverViewport(
        cimgui.c.igGetMainViewport(),
        cimgui.c.ImGuiDockNodeFlags_None,
        null,
    );

    var show: bool = true;
    cimgui.c.igShowDemoWindow(&show);
}
