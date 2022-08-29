//! A library represents the shared state that the underlying font
//! library implementation(s) require per-process.
//!
//! In the future, this will be abstracted so that the underlying text
//! engine might not be Freetype and may be something like Core Text,
//! but the API will remain the same.
const Library = @This();

const freetype = @import("freetype");

lib: freetype.Library,

pub fn init() freetype.Error!Library {
    return Library{ .lib = try freetype.Library.init() };
}

pub fn deinit(self: *Library) void {
    self.lib.deinit();
}
