const std = @import("std");
const c = @import("c.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");
const testEnsureInit = @import("testing.zig").ensureInit;
const Region = @import("region.zig").Region;
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
        _ = try errors.convertError(c.onig_new(
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

    /// onig_search shorthand to search an entire string.
    pub fn search(
        self: *Regex,
        str: []const u8,
        region: *Region,
        options: Option,
    ) !usize {
        return try self.searchAdvanced(str, 0, str.len, region, options);
    }

    /// onig_search
    pub fn searchAdvanced(
        self: *Regex,
        str: []const u8,
        start: usize,
        end: usize,
        region: *Region,
        options: Option,
    ) !usize {
        const pos = try errors.convertError(c.onig_search(
            self.value,
            str.ptr,
            str.ptr + str.len,
            str.ptr + start,
            str.ptr + end,
            @ptrCast(region),
            options.int(),
        ));

        return @intCast(pos);
    }
};

test {
    const testing = std.testing;

    try testEnsureInit();
    var re = try Regex.init("foo", .{}, Encoding.utf8, Syntax.default, null);
    defer re.deinit();

    var region: Region = .{};
    defer region.deinit();
    const pos = try re.search("hello foo bar", &region, .{});
    try testing.expectEqual(@as(usize, 6), pos);
}
