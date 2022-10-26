const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");
const objc = @import("main.zig");

/// Returns a struct that implements the msgSend function for type T.
/// This is meant to be used with `usingnamespace` to add dispatch
/// capability to a type that supports it.
pub fn MsgSend(comptime T: type) type {
    // 1. T should be a struct
    // 2. T should have a field "value" that can be an "id" (same size)

    return struct {
        /// Invoke a selector on the target, i.e. an instance method on an
        /// object or a class method on a class. The args should be a tuple.
        pub fn msgSend(
            target: T,
            comptime Return: type,
            sel: objc.Sel,
            args: anytype,
        ) Return {
            // Build our function type and call it
            const Fn = MsgSendFn(Return, @TypeOf(target.value), @TypeOf(args));
            const msg_send_ptr = @ptrCast(std.meta.FnPtr(Fn), &c.objc_msgSend);
            const result = @call(.{}, msg_send_ptr, .{ target.value, sel } ++ args);

            // This is a special nicety: if the return type is one of our
            // public structs then we wrap the msgSend id result with it.
            // This lets msgSend magically work with Object and so on.
            const is_pkg_struct = comptime is_pkg_struct: {
                for (@typeInfo(objc).Struct.decls) |decl| {
                    if (decl.is_pub and
                        @TypeOf(@field(objc, decl.name)) == type and
                        Return == @field(objc, decl.name))
                    {
                        break :is_pkg_struct true;
                    }
                }

                break :is_pkg_struct false;
            };

            if (!is_pkg_struct) return result;
            return .{ .value = result };
        }
    };
}

/// This returns a function body type for `obj_msgSend` that matches
/// the given return type, target type, and arguments tuple type.
///
/// obj_msgSend is a really interesting function, because it doesn't act
/// like a typical function. You have to call it with the C ABI as if you're
/// calling the true target function, not as a varargs C function. Therefore
/// you have to cast obj_msgSend to a function pointer type of the final
/// destination function, then call that.
///
/// Example: you have an ObjC function like this:
///
///     @implementation Foo
///     - (void)log: (float)x { /* stuff */ }
///
/// If you call it like this, it won't work (you'll get garbage):
///
///     objc_msgSend(obj, @selector(log:), (float)PI);
///
/// You have to call it like this:
///
///     ((void (*)(id, SEL, float))objc_msgSend)(obj, @selector(log:), M_PI);
///
/// This comptime function returns the function body type that can be used
/// to cast and call for the proper C ABI behavior.
fn MsgSendFn(
    comptime Return: type,
    comptime Target: type,
    comptime Args: type,
) type {
    const argsInfo = @typeInfo(Args).Struct;
    assert(argsInfo.is_tuple);

    // Target must always be an "id". Lots of types (Class, Object, etc.)
    // are an "id" so we just make sure the sizes match for ABI reasons.
    assert(@sizeOf(Target) == @sizeOf(c.id));

    // Build up our argument types.
    const Fn = std.builtin.Type.Fn;
    const args: []Fn.Param = args: {
        var acc: [argsInfo.fields.len + 2]Fn.Param = undefined;

        // First argument is always the target and selector.
        acc[0] = .{ .arg_type = Target, .is_generic = false, .is_noalias = false };
        acc[1] = .{ .arg_type = objc.Sel, .is_generic = false, .is_noalias = false };

        // Remaining arguments depend on the args given, in the order given
        for (argsInfo.fields) |field, i| {
            acc[i + 2] = .{
                .arg_type = field.field_type,
                .is_generic = false,
                .is_noalias = false,
            };
        }

        break :args &acc;
    };

    // Copy the alignment of a normal function type so equality works
    // (mainly for tests, I don't think this has any consequence otherwise)
    const alignment = @typeInfo(fn () callconv(.C) void).Fn.alignment;

    return @Type(.{
        .Fn = .{
            .calling_convention = .C,
            .alignment = alignment,
            .is_generic = false,
            .is_var_args = false,
            .return_type = Return,
            .args = args,
        },
    });
}

test {
    // https://github.com/ziglang/zig/issues/12360
    if (true) return error.SkipZigTest;

    const testing = std.testing;
    try testing.expectEqual(fn (
        u8,
        objc.Sel,
    ) callconv(.C) u64, MsgSendFn(u64, u8, @TypeOf(.{})));
    try testing.expectEqual(fn (u8, objc.Sel, u16, u32) callconv(.C) u64, MsgSendFn(u64, u8, @TypeOf(.{
        @as(u16, 0),
        @as(u32, 0),
    })));
}
