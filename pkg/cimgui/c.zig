const c = @cImport({
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "1");
    @cInclude("cimgui.h");
});

// Export all of the C API
pub usingnamespace c;

// OpenGL
pub extern fn ImGui_ImplOpenGL3_Init(?[*:0]const u8) callconv(.C) void;
pub extern fn ImGui_ImplOpenGL3_Shutdown() callconv(.C) void;
pub extern fn ImGui_ImplOpenGL3_NewFrame() callconv(.C) void;
pub extern fn ImGui_ImplOpenGL3_RenderDrawData(*c.ImDrawData) callconv(.C) void;
