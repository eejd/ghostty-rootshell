const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

// TODO:
//   - Only `--long=value` format is accepted. Do we want to allow
//     `--long value`? Not currently allowed.

/// Parse the command line arguments from iter into dst.
///
/// dst must be a struct. The fields and their types will be used to determine
/// the valid CLI flags. See the tests in this file as an example. For field
/// types that are structs, the struct can implement the `parseCLI` function
/// to do custom parsing.
pub fn parse(comptime T: type, alloc: Allocator, dst: *T, iter: anytype) !void {
    const info = @typeInfo(T);
    assert(info == .Struct);

    // Make an arena for all our allocations if we support it. Otherwise,
    // use an allocator that always fails.
    const arena_alloc = if (@hasField(T, "_arena")) arena: {
        dst._arena = ArenaAllocator.init(alloc);
        break :arena dst._arena.?.allocator();
    } else std.mem.fail_allocator;
    errdefer if (@hasField(T, "_arena")) dst._arena.?.deinit();

    while (iter.next()) |arg| {
        if (mem.startsWith(u8, arg, "--")) {
            var key: []const u8 = arg[2..];
            const value: ?[]const u8 = value: {
                // If the arg has "=" then the value is after the "=".
                if (mem.indexOf(u8, key, "=")) |idx| {
                    defer key = key[0..idx];
                    break :value key[idx + 1 ..];
                }

                break :value null;
            };

            try parseIntoField(T, arena_alloc, dst, key, value);
        }
    }
}

/// Parse a single key/value pair into the destination type T.
///
/// This may result in allocations. The allocations can only be freed by freeing
/// all the memory associated with alloc. It is expected that alloc points to
/// an arena.
fn parseIntoField(
    comptime T: type,
    alloc: Allocator,
    dst: *T,
    key: []const u8,
    value: ?[]const u8,
) !void {
    const info = @typeInfo(T);
    assert(info == .Struct);

    inline for (info.Struct.fields) |field| {
        if (mem.eql(u8, field.name, key)) {
            // For optional fields, we just treat it as the child type.
            // This lets optional fields default to null but get set by
            // the CLI.
            const Field = switch (@typeInfo(field.field_type)) {
                .Optional => |opt| opt.child,
                else => field.field_type,
            };
            const fieldInfo = @typeInfo(Field);

            // If we are a struct and have parseCLI, we call that and use
            // that to set the value.
            if (fieldInfo == .Struct and @hasDecl(Field, "parseCLI")) {
                const fnInfo = @typeInfo(@TypeOf(Field.parseCLI)).Fn;
                switch (fnInfo.args.len) {
                    // 1 arg = (input) => output
                    1 => @field(dst, field.name) = try Field.parseCLI(value),

                    // 2 arg = (self, input) => void
                    2 => try @field(dst, field.name).parseCLI(value),

                    // 3 arg = (self, alloc, input) => void
                    3 => try @field(dst, field.name).parseCLI(alloc, value),

                    else => @compileError("parseCLI invalid argument count"),
                }

                return;
            }

            // No parseCLI, magic the value based on the type
            @field(dst, field.name) = switch (Field) {
                []const u8 => if (value) |slice| value: {
                    const buf = try alloc.alloc(u8, slice.len);
                    mem.copy(u8, buf, slice);
                    break :value buf;
                } else return error.ValueRequired,

                bool => try parseBool(value orelse "t"),

                u8 => try std.fmt.parseInt(u8, value orelse return error.ValueRequired, 0),

                else => unreachable,
            };

            return;
        }
    }

    return error.InvalidFlag;
}

fn parseBool(v: []const u8) !bool {
    const t = &[_][]const u8{ "1", "t", "T", "true" };
    const f = &[_][]const u8{ "0", "f", "F", "false" };

    inline for (t) |str| {
        if (mem.eql(u8, v, str)) return true;
    }
    inline for (f) |str| {
        if (mem.eql(u8, v, str)) return false;
    }

    return error.InvalidBooleanValue;
}

test "parse: simple" {
    const testing = std.testing;

    var data: struct {
        a: []const u8 = "",
        b: bool = false,
        @"b-f": bool = true,

        _arena: ?ArenaAllocator = null,
    } = .{};
    defer if (data._arena) |arena| arena.deinit();

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--a=42 --b --b-f=false",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expect(data._arena != null);
    try testing.expectEqualStrings("42", data.a);
    try testing.expect(data.b);
    try testing.expect(!data.@"b-f");
}

test "parseIntoField: string" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: []const u8,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqualStrings("42", data.a);
}

test "parseIntoField: bool" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: bool,
    } = undefined;

    // True
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "1");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "t");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "T");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "true");
    try testing.expectEqual(true, data.a);

    // False
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "0");
    try testing.expectEqual(false, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "f");
    try testing.expectEqual(false, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "F");
    try testing.expectEqual(false, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "false");
    try testing.expectEqual(false, data.a);
}

test "parseIntoField: unsigned numbers" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        @"u8": u8,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "u8", "1");
    try testing.expectEqual(@as(u8, 1), data.@"u8");
}

test "parseIntoField: optional field" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: ?bool = null,
    } = .{};

    // True
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "1");
    try testing.expectEqual(true, data.a.?);
}

test "parseIntoField: struct with parse func" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: struct {
            const Self = @This();

            v: []const u8,

            pub fn parseCLI(value: ?[]const u8) !Self {
                _ = value;
                return Self{ .v = "HELLO!" };
            }
        },
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqual(@as([]const u8, "HELLO!"), data.a.v);
}
