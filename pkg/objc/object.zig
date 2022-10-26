const std = @import("std");
const c = @import("c.zig");
const objc = @import("main.zig");
const MsgSend = @import("msg_send.zig").MsgSend;

pub const Object = struct {
    value: c.id,

    pub usingnamespace MsgSend(Object);
};

test {
    const testing = std.testing;
    const NSObject = objc.Class.getClass("NSObject").?;

    // Should work with our wrappers
    const obj = NSObject.msgSend(objc.Object, objc.Sel.registerName("alloc"), .{});
    try testing.expect(obj.value != null);
    obj.msgSend(void, objc.sel("dealloc"), .{});
}
