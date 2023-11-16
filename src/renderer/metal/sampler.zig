const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const objc = @import("objc");

pub const Sampler = struct {
    sampler: objc.Object,

    pub fn init(device: objc.Object) !Sampler {
        const desc = init: {
            const Class = objc.getClass("MTLSamplerDescriptor").?;
            const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
            const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
            break :init id_init;
        };
        defer desc.msgSend(void, objc.sel("release"), .{});

        const sampler = device.msgSend(
            objc.Object,
            objc.sel("newSamplerStateWithDescriptor:"),
            .{desc},
        );
        errdefer sampler.msgSend(void, objc.sel("release"), .{});

        return .{ .sampler = sampler };
    }

    pub fn deinit(self: *Sampler) void {
        self.sampler.msgSend(void, objc.sel("release"), .{});
    }
};
