const std = @import("std");
const c = @import("c.zig");

pub const Region = extern struct {
    allocated: c_int = 0,
    num_regs: c_int = 0,
    beg: ?[*]c_int = null,
    end: ?[*]c_int = null,
    history_root: ?*c.OnigCaptureTreeNode = null, // TODO: convert to Zig

    pub fn deinit(self: *Region) void {
        // We never free ourself because allocation of Region in the Zig
        // bindings is handled by the Zig program.
        c.onig_region_free(@ptrCast(self), 0);
    }
};
