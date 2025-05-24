const std = @import("std");

const assert = std.debug.assert;

/// Datastructure to manage a (usually) small list of items. To prevent
/// allocations on the heap, statically allocate a small array that gets used to
/// store items. Once that small array is full then memory will be dynamically
/// allocated on the heap to store items.
pub fn ArrayListStaticUnmanaged(comptime static_size: usize, comptime T: type) type {
    return struct {
        count: usize,
        static: [static_size]T,
        dynamic: std.ArrayListUnmanaged(T),

        const Self = @This();

        pub const empty: Self = .{
            .count = 0,
            .static = undefined,
            .dynamic = .empty,
        };

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.dynamic.deinit(alloc);
        }

        pub fn append(self: *Self, alloc: std.mem.Allocator, item: T) !void {
            if (self.count < static_size) {
                self.static[self.count] = item;
                self.count += 1;
                assert(self.count <= static_size);
                return;
            }
            try self.dynamic.append(alloc, item);
            self.count += 1;
            assert(self.count == static_size + self.dynamic.items.len);
        }

        pub const Iterator = struct {
            context: *const Self,
            index: usize,

            pub fn next(self: *Iterator) ?T {
                if (self.index >= self.context.count) return null;

                if (self.index < static_size) {
                    defer self.index += 1;
                    return self.context.static[self.index];
                }

                assert(self.index - static_size < self.context.dynamic.items.len);

                defer self.index += 1;
                return self.context.dynamic.items[self.index - static_size];
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{
                .context = self,
                .index = 0,
            };
        }
    };
}

test "ArrayListStaticUnmanged: 1" {
    const alloc = std.testing.allocator;

    var l: ArrayListStaticUnmanaged(1, usize) = .empty;
    defer l.deinit(alloc);

    try l.append(alloc, 1);

    try std.testing.expectEqual(1, l.count);
    try std.testing.expectEqual(1, l.static[0]);
    try std.testing.expectEqual(0, l.dynamic.items.len);

    var it = l.iterator();
    try std.testing.expectEqual(1, it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "ArrayListStaticUnmanged: 2" {
    const alloc = std.testing.allocator;

    var l: ArrayListStaticUnmanaged(1, usize) = .empty;
    defer l.deinit(alloc);

    try l.append(alloc, 1);
    try l.append(alloc, 2);

    try std.testing.expectEqual(2, l.count);
    try std.testing.expectEqual(1, l.static[0]);
    try std.testing.expectEqual(1, l.dynamic.items.len);
    var it = l.iterator();
    try std.testing.expectEqual(1, it.next().?);
    try std.testing.expectEqual(2, it.next().?);
    try std.testing.expectEqual(null, it.next());
}
