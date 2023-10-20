//! The Inspector is a development tool to debug the terminal. This is
//! useful for terminal application developers as well as people potentially
//! debugging issues in Ghostty itself.
const Inspector = @This();

const cimgui = @import("cimgui");

/// Setup the ImGui state. This requires an ImGui context to be set.
pub fn setup() void {
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();

    // Enable docking, which we use heavily for the UI.
    io.ConfigFlags |= cimgui.c.ImGuiConfigFlags_DockingEnable;

    // Our colorspace is sRGB.
    io.ConfigFlags |= cimgui.c.ImGuiConfigFlags_IsSRGB;
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
