//! The Inspector is a development tool to debug the terminal. This is
//! useful for terminal application developers as well as people potentially
//! debugging issues in Ghostty itself.
const Inspector = @This();

const cimgui = @import("cimgui");

pub fn init() Inspector {
    return .{};
}

pub fn deinit(self: *Inspector) void {
    _ = self;
}

pub fn render(self: *Inspector) void {
    _ = self;

    var show: bool = true;
    cimgui.c.igShowDemoWindow(&show);
}
