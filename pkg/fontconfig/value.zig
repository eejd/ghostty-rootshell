const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");
const CharSet = @import("main.zig").CharSet;
const LangSet = @import("main.zig").LangSet;
const Matrix = @import("main.zig").Matrix;
const Range = @import("main.zig").Range;

pub const Type = enum(c_int) {
    unknown = c.FcTypeUnknown,
    @"void" = c.FcTypeVoid,
    integer = c.FcTypeInteger,
    double = c.FcTypeDouble,
    string = c.FcTypeString,
    @"bool" = c.FcTypeBool,
    matrix = c.FcTypeMatrix,
    char_set = c.FcTypeCharSet,
    ft_face = c.FcTypeFTFace,
    lang_set = c.FcTypeLangSet,
    range = c.FcTypeRange,
};

pub const Value = union(Type) {
    unknown: void,
    @"void": void,
    integer: u32,
    double: f64,
    string: []const u8,
    @"bool": bool,
    matrix: *const Matrix,
    char_set: *const CharSet,
    ft_face: *anyopaque,
    lang_set: *const LangSet,
    range: *const Range,

    pub fn init(cvalue: *c.struct__FcValue) Value {
        return switch (@intToEnum(Type, cvalue.@"type")) {
            .unknown => .{ .unknown = {} },
            .@"void" => .{ .@"void" = {} },
            .string => .{ .string = std.mem.sliceTo(cvalue.u.s, 0) },
            .integer => .{ .integer = @intCast(u32, cvalue.u.i) },
            .double => .{ .double = cvalue.u.d },
            .@"bool" => .{ .@"bool" = cvalue.u.b == c.FcTrue },
            .matrix => .{ .matrix = @ptrCast(*const Matrix, cvalue.u.m) },
            .char_set => .{ .char_set = @ptrCast(*const CharSet, cvalue.u.c) },
            .ft_face => .{ .ft_face = @ptrCast(*anyopaque, cvalue.u.f) },
            .lang_set => .{ .lang_set = @ptrCast(*const LangSet, cvalue.u.l) },
            .range => .{ .range = @ptrCast(*const Range, cvalue.u.r) },
        };
    }
};

pub const ValueBinding = enum(c_int) {
    weak = c.FcValueBindingWeak,
    strong = c.FcValueBindingStrong,
    same = c.FcValueBindingSame,
};
