const std = @import("std");
const c = @import("c.zig");
const objc = @import("main.zig");
const MsgSend = @import("msg_send.zig").MsgSend;

pub const Object = struct {
    value: c.id,

    pub usingnamespace MsgSend(Object);
};
