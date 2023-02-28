const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");
const CharSet = @import("main.zig").CharSet;
const LangSet = @import("main.zig").LangSet;
const Matrix = @import("main.zig").Matrix;
const Range = @import("main.zig").Range;

pub const Type = enum(c_int) {
    unknown = c.FcTypeUnknown,
    void = c.FcTypeVoid,
    integer = c.FcTypeInteger,
    double = c.FcTypeDouble,
    string = c.FcTypeString,
    bool = c.FcTypeBool,
    matrix = c.FcTypeMatrix,
    char_set = c.FcTypeCharSet,
    ft_face = c.FcTypeFTFace,
    lang_set = c.FcTypeLangSet,
    range = c.FcTypeRange,
};

pub const Value = union(Type) {
    unknown: void,
    void: void,
    integer: i32,
    double: f64,
    string: [:0]const u8,
    bool: bool,
    matrix: *const Matrix,
    char_set: *const CharSet,
    ft_face: *anyopaque,
    lang_set: *const LangSet,
    range: *const Range,

    pub fn init(cvalue: *c.struct__FcValue) Value {
        return switch (@intToEnum(Type, cvalue.type)) {
            .unknown => .{ .unknown = {} },
            .void => .{ .void = {} },
            .string => .{ .string = std.mem.sliceTo(cvalue.u.s, 0) },
            .integer => .{ .integer = @intCast(i32, cvalue.u.i) },
            .double => .{ .double = cvalue.u.d },
            .bool => .{ .bool = cvalue.u.b == c.FcTrue },
            .matrix => .{ .matrix = @ptrCast(*const Matrix, cvalue.u.m) },
            .char_set => .{ .char_set = @ptrCast(*const CharSet, cvalue.u.c) },
            .ft_face => .{ .ft_face = @ptrCast(*anyopaque, cvalue.u.f) },
            .lang_set => .{ .lang_set = @ptrCast(*const LangSet, cvalue.u.l) },
            .range => .{ .range = @ptrCast(*const Range, cvalue.u.r) },
        };
    }

    pub fn cval(self: Value) c.struct__FcValue {
        return .{
            .type = @enumToInt(std.meta.activeTag(self)),
            .u = switch (self) {
                .unknown => undefined,
                .void => undefined,
                .integer => |v| .{ .i = @intCast(c_int, v) },
                .double => |v| .{ .d = v },
                .string => |v| .{ .s = v.ptr },
                .bool => |v| .{ .b = if (v) c.FcTrue else c.FcFalse },
                .matrix => |v| .{ .m = @ptrCast(*const c.struct__FcMatrix, v) },
                .char_set => |v| .{ .c = @ptrCast(*const c.struct__FcCharSet, v) },
                .ft_face => |v| .{ .f = v },
                .lang_set => |v| .{ .l = @ptrCast(*const c.struct__FcLangSet, v) },
                .range => |v| .{ .r = @ptrCast(*const c.struct__FcRange, v) },
            },
        };
    }
};

pub const ValueBinding = enum(c_int) {
    weak = c.FcValueBindingWeak,
    strong = c.FcValueBindingStrong,
    same = c.FcValueBindingSame,
};
