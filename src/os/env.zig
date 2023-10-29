const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Append a value to an environment variable such as PATH.
/// The returned value is always allocated so it must be freed.
pub fn appendEnv(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) ![]u8 {
    // If there is no prior value, we return it as-is
    if (current.len == 0) return try alloc.dupe(u8, value);

    // Otherwise we must prefix.
    const sep = switch (builtin.os.tag) {
        .windows => ";",
        else => ":",
    };

    return try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{
        current,
        sep,
        value,
    });
}

test "appendEnv empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try appendEnv(alloc, "", "foo");
    defer alloc.free(result);
    try testing.expectEqualStrings(result, "foo");
}

test "appendEnv existing" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try appendEnv(alloc, "a:b", "foo");
    defer alloc.free(result);
    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings(result, "a:b;foo");
    } else {
        try testing.expectEqualStrings(result, "a:b:foo");
    }
}

extern "c" fn setenv(name: ?[*]const u8, value: ?[*]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: ?[*]const u8) c_int;
extern "c" fn _putenv_s(varname: ?[*]const u8, value_string: ?[*]const u8) c_int;

pub fn setEnv(key: [:0]const u8, value: [:0]const u8) c_int {
    if (builtin.os.tag == .windows) {
        return _putenv_s(key.ptr, value.ptr);
    } else {
        return setenv(key.ptr, value.ptr, 1);
    }
}

pub fn unsetEnv(key: [:0]const u8) c_int {
    if (builtin.os.tag == .windows) {
        return _putenv_s(key.ptr, "");
    } else {
        return unsetenv(key.ptr);
    }
}

/// Returns the value of an environment variable, or null if not found.
/// The returned value is always allocated so it must be freed.
pub fn getEnvVarOwned(alloc: std.mem.Allocator, key: []const u8) !?[]u8 {
    if (std.process.getEnvVarOwned(alloc, key)) |v| {
        return v;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    return null;
}
