// This is the main file for the WASM module. The WASM module has to
// export a C ABI compatible API.

pub usingnamespace @import("wasm.zig");
pub usingnamespace @import("font/main.zig");

// TODO: temporary while we dev this
pub usingnamespace @import("font/face/web_canvas.zig");
