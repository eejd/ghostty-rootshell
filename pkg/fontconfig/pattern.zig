const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");
const ObjectSet = @import("main.zig").ObjectSet;
const Result = @import("main.zig").Result;
const Value = @import("main.zig").Value;
const ValueBinding = @import("main.zig").ValueBinding;

pub const Pattern = opaque {
    pub fn create() *Pattern {
        return @ptrCast(*Pattern, c.FcPatternCreate());
    }

    pub fn parse(str: [:0]const u8) *Pattern {
        return @ptrCast(*Pattern, c.FcNameParse(str.ptr));
    }

    pub fn destroy(self: *Pattern) void {
        c.FcPatternDestroy(self.cval());
    }

    pub fn defaultSubstitute(self: *Pattern) void {
        c.FcDefaultSubstitute(self.cval());
    }

    pub fn delete(self: *Pattern, obj: [:0]const u8) bool {
        return c.FcPatternDel(self.cval(), obj.ptr) == c.FcTrue;
    }

    pub fn filter(self: *Pattern, os: *const ObjectSet) *Pattern {
        return @ptrCast(*Pattern, c.FcPatternFilter(self.cval(), os.cval()));
    }

    pub fn objectIterator(self: *Pattern) ObjectIterator {
        return .{ .pat = self.cval(), .iter = null };
    }

    pub fn print(self: *Pattern) void {
        c.FcPatternPrint(self.cval());
    }

    pub inline fn cval(self: *Pattern) *c.struct__FcPattern {
        return @ptrCast(*c.struct__FcPattern, self);
    }

    pub const ObjectIterator = struct {
        pat: *c.struct__FcPattern,
        iter: ?c.struct__FcPatternIter,

        /// Move to the next object, returns true if there is another
        /// object and false otherwise. If this is the first call, this
        /// will be teh first object.
        pub fn next(self: *ObjectIterator) bool {
            // Null means our first iterator
            if (self.iter == null) {
                // If we have no objects, do not create iterator
                if (c.FcPatternObjectCount(self.pat) == 0) return false;

                var iter: c.struct__FcPatternIter = undefined;
                c.FcPatternIterStart(
                    self.pat,
                    &iter,
                );
                assert(c.FcPatternIterIsValid(self.pat, &iter) == c.FcTrue);
                self.iter = iter;

                // Return right away because the fontconfig iterator pattern
                // is do/while.
                return true;
            }

            return c.FcPatternIterNext(
                self.pat,
                @ptrCast([*c]c.struct__FcPatternIter, &self.iter),
            ) == c.FcTrue;
        }

        pub fn object(self: *ObjectIterator) []const u8 {
            return std.mem.sliceTo(c.FcPatternIterGetObject(
                self.pat,
                &self.iter.?,
            ), 0);
        }

        pub fn valueLen(self: *ObjectIterator) usize {
            return @intCast(usize, c.FcPatternIterValueCount(self.pat, &self.iter.?));
        }

        pub fn valueIterator(self: *ObjectIterator) ValueIterator {
            return .{
                .pat = self.pat,
                .iter = &self.iter.?,
                .max = c.FcPatternIterValueCount(self.pat, &self.iter.?),
            };
        }
    };

    pub const ValueIterator = struct {
        pat: *c.struct__FcPattern,
        iter: *c.struct__FcPatternIter,
        max: c_int,
        id: c_int = 0,

        pub const Entry = struct {
            result: Result,
            value: Value,
            binding: ValueBinding,
        };

        pub fn next(self: *ValueIterator) ?Entry {
            if (self.id >= self.max) return null;
            var value: c.struct__FcValue = undefined;
            var binding: c.FcValueBinding = undefined;
            const result = c.FcPatternIterGetValue(self.pat, self.iter, self.id, &value, &binding);
            self.id += 1;

            return Entry{
                .result = @intToEnum(Result, result),
                .binding = @intToEnum(ValueBinding, binding),
                .value = Value.init(&value),
            };
        }
    };
};

test "create" {
    var pat = Pattern.create();
    defer pat.destroy();
}

test "name parse" {
    var pat = Pattern.parse(":monospace");
    defer pat.destroy();

    pat.defaultSubstitute();
}
