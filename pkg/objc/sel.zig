const std = @import("std");
const c = @import("c.zig");

pub const Sel = struct {
    value: c.SEL,

    /// Registers a method with the Objective-C runtime system, maps the
    /// method name to a selector, and returns the selector value.
    pub fn registerName(name: [:0]const u8) Sel {
        return Sel{
            .value = c.sel_registerName(name.ptr),
        };
    }

    /// Returns the name of the method specified by a given selector.
    pub fn getName(self: Sel) [:0]const u8 {
        return std.mem.sliceTo(c.sel_getName(self.value), 0);
    }
};

test {
    const testing = std.testing;
    const sel = Sel.registerName("yo");
    try testing.expectEqualStrings("yo", sel.getName());
}
