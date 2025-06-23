const std = @import("std");
const Allocator = std.mem.Allocator;

/// A pool of ArrayLists with methods for bulk operations.
pub fn ArrayListPool(comptime T: type) type {
    return struct {
        const Self = ArrayListPool(T);
        const ArrayListT = std.ArrayListUnmanaged(T);

        // An array containing the lists that belong to this pool.
        lists: []ArrayListT = &[_]ArrayListT{},

        // The pool will be initialized with empty ArrayLists.
        pub fn init(
            alloc: Allocator,
            list_count: usize,
            initial_capacity: usize,
        ) Allocator.Error!Self {
            const self: Self = .{
                .lists = try alloc.alloc(ArrayListT, list_count),
            };

            for (self.lists) |*list| {
                list.* = try .initCapacity(alloc, initial_capacity);
            }

            return self;
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.lists) |*list| {
                list.deinit(alloc);
            }
            alloc.free(self.lists);
        }

        /// Clear all lists in the pool.
        pub fn reset(self: *Self) void {
            for (self.lists) |*list| {
                list.clearRetainingCapacity();
            }
        }
    };
}
