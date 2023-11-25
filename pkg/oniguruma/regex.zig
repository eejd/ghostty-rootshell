const std = @import("std");
const c = @import("c.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");
const testEnsureInit = @import("testing.zig").ensureInit;
const ErrorInfo = errors.ErrorInfo;
const Encoding = types.Encoding;
const Option = types.Option;
const Syntax = types.Syntax;

pub const Regex = struct {
    value: c.OnigRegex,

    pub fn init(
        pattern: []const u8,
        options: Option,
        enc: *Encoding,
        syntax: *Syntax,
        err: ?*ErrorInfo,
    ) !Regex {
        var self: Regex = undefined;
        try errors.convertError(c.onig_new(
            &self.value,
            pattern.ptr,
            pattern.ptr + pattern.len,
            options.int(),
            @ptrCast(@alignCast(enc)),
            @ptrCast(@alignCast(syntax)),
            @ptrCast(err),
        ));
        return self;
    }

    pub fn deinit(self: *Regex) void {
        c.onig_free(self.value);
    }
};

test {
    try testEnsureInit();
    var re = try Regex.init("foo", .{}, Encoding.utf8, Syntax.default, null);
    defer re.deinit();
}
