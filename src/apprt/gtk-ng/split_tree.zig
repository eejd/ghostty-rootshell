const std = @import("std");
const assert = std.debug.assert;
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;

/// SplitTree represents a tree of view types that can be divided.
///
/// Concretely for Ghostty, it represents a tree of terminal views. In
/// its basic state, there are no splits and it is a single full-sized
/// terminal. However, it can be split arbitrarily many times among two
/// axes (horizontal and vertical) to create a tree of terminal views.
///
/// This is an immutable tree structure, meaning all operations on it
/// will return a new tree with the operation applied. This allows us to
/// store versions of the tree in a history for easy undo/redo. To facilitate
/// this, the stored View type must implement reference counting; this is left
/// as an implementation detail of the View type.
///
/// The View type will be stored as a pointer within the tree and must
/// implement a number of functions to work properly:
///
///   - `fn ref(*View, Allocator) Allocator.Error!*View` - Increase a
///     reference count of the view. The Allocator will be the allocator provided
///     to the tree operation. This is allowed to copy the value if it wants to;
///     the returned value is expected to be a new reference (but that may
///     just be a copy).
///
///   - `fn unref(*View, Allocator) void` - Decrease the reference count of a
///     view. The Allocator will be the allocator provided to the tree
///     operation.
///
///   - `fn eql(*const View, *const View) bool` - Check if two views are equal.
///
pub fn SplitTree(comptime V: type) type {
    return struct {
        const Self = @This();

        /// The view that this tree contains.
        pub const View = V;

        /// The arena allocator used for all allocations in the tree.
        /// Since the tree is an immutable structure, this lets us
        /// cleanly free all memory when the tree is deinitialized.
        arena: ArenaAllocator,

        /// All the nodes in the tree. Node at index 0 is always the root.
        nodes: []const Node,

        /// An empty tree.
        pub const empty: Self = .{
            // Arena can be undefined because we have zero allocated nodes.
            // If our nodes are empty our deinit function doesn't touch the
            // arena.
            .arena = undefined,
            .nodes = &.{},
        };

        pub const Node = union(enum) {
            leaf: *View,
            split: Split,

            /// A handle into the nodes array. This lets us keep track of
            /// nodes with 16-bit handles rather than full pointer-width
            /// values.
            pub const Handle = u16;
        };

        pub const Split = struct {
            layout: Layout,
            ratio: f16,
            left: Node.Handle,
            right: Node.Handle,

            pub const Layout = enum { horizontal, vertical };
            pub const Direction = enum { left, right, down, up };
        };

        /// Initialize a new tree with a single view.
        pub fn init(gpa: Allocator, view: *View) Allocator.Error!Self {
            var arena = ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();

            const nodes = try alloc.alloc(Node, 1);
            nodes[0] = .{ .leaf = try view.ref(gpa) };
            errdefer view.unref(gpa);

            return .{
                .arena = arena,
                .nodes = nodes,
            };
        }

        pub fn deinit(self: *Self) void {
            // Important: only free memory if we have memory to free,
            // because we use an undefined arena for empty trees.
            if (self.nodes.len > 0) {
                // Unref all our views
                const gpa: Allocator = self.arena.child_allocator;
                for (self.nodes) |node| switch (node) {
                    .leaf => |view| view.unref(gpa),
                    .split => {},
                };
                self.arena.deinit();
            }

            self.* = undefined;
        }

        /// Insert another tree into this tree at the given node in the
        /// specified direction. The other tree will be inserted in the
        /// new direction. For example, if the direction is "right" then
        /// `insert` is inserted right of the existing node.
        ///
        /// The allocator will be used for the newly created tree.
        /// The previous trees will not be freed, but reference counts
        /// for the views will be increased accordingly for the new tree.
        pub fn split(
            self: *const Self,
            gpa: Allocator,
            at: Node.Handle,
            direction: Split.Direction,
            insert: *const Self,
        ) Allocator.Error!Self {
            // The new arena for our new tree.
            var arena = ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();

            // We know we're going to need the sum total of the nodes
            // between the two trees plus one for the new split node.
            const nodes = try alloc.alloc(Node, self.nodes.len + insert.nodes.len + 1);
            if (nodes.len > std.math.maxInt(Node.Handle)) return error.OutOfMemory;

            // We can copy our nodes exactly as they are, since they're
            // mostly not changing (only `at` is changing).
            @memcpy(nodes[0..self.nodes.len], self.nodes);

            // We can copy the destination nodes as well directly next to
            // the source nodes. We just have to go through and offset
            // all the handles in the destination tree to account for
            // the shift.
            const nodes_inserted = nodes[self.nodes.len..][0..insert.nodes.len];
            @memcpy(nodes_inserted, insert.nodes);
            for (nodes_inserted) |*node| switch (node.*) {
                .leaf => {},
                .split => |*s| {
                    // We need to offset the handles in the split
                    s.left += @intCast(self.nodes.len);
                    s.right += @intCast(self.nodes.len);
                },
            };

            // Determine our split layout and if we're on the left
            const layout: Split.Layout, const left: bool = switch (direction) {
                .left => .{ .horizontal, true },
                .right => .{ .horizontal, false },
                .up => .{ .vertical, true },
                .down => .{ .vertical, false },
            };

            // Copy our previous value to the end of the nodes list and
            // create our new split node.
            nodes[nodes.len - 1] = nodes[at];
            nodes[at] = .{ .split = .{
                .layout = layout,
                .ratio = 0.5,
                .left = @intCast(if (left) self.nodes.len else nodes.len - 1),
                .right = @intCast(if (left) nodes.len - 1 else self.nodes.len),
            } };

            // We need to increase the reference count of all the nodes.
            // Careful accounting here so that we properly unref on error
            // only the nodes we referenced.
            var reffed: usize = 0;
            errdefer for (0..reffed) |i| {
                switch (nodes[i]) {
                    .split => {},
                    .leaf => |view| view.unref(gpa),
                }
            };
            for (0..nodes.len) |i| {
                switch (nodes[i]) {
                    .split => {},
                    .leaf => |view| nodes[i] = .{ .leaf = try view.ref(gpa) },
                }
                reffed = i;
            }
            assert(reffed == nodes.len - 1);

            return .{ .arena = arena, .nodes = nodes };
        }

        /// Spatial representation of the split tree. This can be used to
        /// better understand the layout of the tree in a 2D space.
        ///
        /// The bounds of the representation are always based on each split
        /// being exactly 1 unit wide and high. The x and y coordinates
        /// are offsets into that space. This means that the spatial
        /// representation is a normalized representation of the actual
        /// space.
        ///
        /// The top-left corner of the tree is always (0, 0).
        ///
        /// We use a normalized form because we can calculate it without
        /// accessing to the actual rendered view sizes. These actual sizes
        /// may not be available at various times because GUI toolkits often
        /// only make them available once they're part of a widget tree and
        /// a SplitTree can represent views that aren't currently visible.
        pub const Spatial = struct {
            /// The slots of the spatial representation in the same order
            /// as the tree it was created from.
            slots: []const Slot,

            pub const empty: Spatial = .{ .slots = &.{} };

            const Slot = struct {
                x: f16,
                y: f16,
                width: f16,
                height: f16,
            };

            pub fn deinit(self: *const Spatial, alloc: Allocator) void {
                alloc.free(self.slots);
                self.* = undefined;
            }
        };

        /// Returns the spatial representation of this tree. See Spatial
        /// for more details.
        pub fn spatial(
            self: *const Self,
            alloc: Allocator,
        ) Allocator.Error!Spatial {
            // No nodes, empty spatial representation.
            if (self.nodes.len == 0) return .empty;

            // Get our total dimensions.
            const dim = self.dimensions(0);

            // Create our slots which will match our nodes exactly.
            const slots = try alloc.alloc(Spatial.Slot, self.nodes.len);
            errdefer alloc.free(slots);
            slots[0] = .{
                .x = 0,
                .y = 0,
                .width = dim.width,
                .height = dim.height,
            };
            self.fillSpatialSlots(slots, 0);

            return .{ .slots = slots };
        }

        fn fillSpatialSlots(
            self: *const Self,
            slots: []Spatial.Slot,
            current: Node.Handle,
        ) void {
            assert(slots[current].width > 0 and slots[current].height > 0);

            switch (self.nodes[current]) {
                // Leaf node, current slot is already filled by caller.
                .leaf => {},

                .split => |s| {
                    switch (s.layout) {
                        .horizontal => {
                            slots[s.left] = .{
                                .x = slots[current].x,
                                .y = slots[current].y,
                                .width = slots[current].width * s.ratio,
                                .height = slots[current].height,
                            };
                            slots[s.right] = .{
                                .x = slots[current].x + slots[current].width * s.ratio,
                                .y = slots[current].y,
                                .width = slots[current].width * (1 - s.ratio),
                                .height = slots[current].height,
                            };
                        },

                        .vertical => {
                            slots[s.left] = .{
                                .x = slots[current].x,
                                .y = slots[current].y,
                                .width = slots[current].width,
                                .height = slots[current].height * s.ratio,
                            };
                            slots[s.right] = .{
                                .x = slots[current].x,
                                .y = slots[current].y + slots[current].height * s.ratio,
                                .width = slots[current].width,
                                .height = slots[current].height * (1 - s.ratio),
                            };
                        },
                    }

                    self.fillSpatialSlots(slots, s.left);
                    self.fillSpatialSlots(slots, s.right);
                },
            }
        }

        /// Get the dimensions of the tree starting from the given node.
        ///
        /// This creates relative dimensions (see Spatial) by assuming each
        /// leaf is exactly 1x1 unit in size.
        fn dimensions(self: *const Self, current: Node.Handle) struct {
            width: u16,
            height: u16,
        } {
            return switch (self.nodes[current]) {
                .leaf => .{ .width = 1, .height = 1 },
                .split => |s| split: {
                    const left = self.dimensions(s.left);
                    const right = self.dimensions(s.right);
                    break :split switch (s.layout) {
                        .horizontal => .{
                            .width = left.width + right.width,
                            .height = @max(left.height, right.height),
                        },

                        .vertical => .{
                            .width = @max(left.width, right.width),
                            .height = left.height + right.height,
                        },
                    };
                },
            };
        }

        /// Format the tree in a human-readable format.
        ///
        /// NOTE: This is currently in node-order but we should change this
        /// to spatial ASCII drawings once we have better support for that.
        pub fn format(
            self: *const Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            if (self.nodes.len == 0) {
                try writer.writeAll("empty");
            } else {
                try self.formatNode(writer, 0, 0);
            }
        }

        fn formatNode(
            self: *const Self,
            writer: anytype,
            handle: Node.Handle,
            depth: usize,
        ) !void {
            const node = self.nodes[handle];

            // Write indentation
            for (0..depth) |_| try writer.writeAll("  ");

            // Write node
            switch (node) {
                .leaf => try writer.print("leaf({d})", .{handle}),
                .split => |s| {
                    try writer.print(
                        "split({s}, {d:.2})\n",
                        .{ @tagName(s.layout), s.ratio },
                    );
                    try self.formatNode(writer, s.left, depth + 1);
                    try writer.writeAll("\n");
                    try self.formatNode(writer, s.right, depth + 1);
                },
            }
        }
    };
}

const TestTree = SplitTree(TestView);

const TestView = struct {
    const Self = @This();

    pub fn ref(self: *Self, alloc: Allocator) Allocator.Error!*Self {
        const ptr = try alloc.create(Self);
        ptr.* = self.*;
        return ptr;
    }

    pub fn unref(self: *Self, alloc: Allocator) void {
        alloc.destroy(self);
    }
};

test "SplitTree: empty tree" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: TestTree = .empty;
    defer t.deinit();

    const str = try std.fmt.allocPrint(alloc, "{}", .{t});
    defer alloc.free(str);
    try testing.expectEqualStrings(str,
        \\empty
    );
}

test "SplitTree: single node" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v: TestTree.View = .{};
    var t: TestTree = try .init(alloc, &v);
    defer t.deinit();

    const str = try std.fmt.allocPrint(alloc, "{}", .{t});
    defer alloc.free(str);
    try testing.expectEqualStrings(str,
        \\leaf(0)
    );
}

test "SplitTree: split" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v: TestTree.View = .{};

    var t1: TestTree = try .init(alloc, &v);
    defer t1.deinit();
    var t2: TestTree = try .init(alloc, &v);
    defer t2.deinit();

    var t3 = try t1.split(
        alloc,
        0, // at root
        .right, // split right
        &t2, // insert t2
    );
    defer t3.deinit();

    const str = try std.fmt.allocPrint(alloc, "{}", .{t3});
    defer alloc.free(str);
    try testing.expectEqualStrings(str,
        \\split(horizontal, 0.50)
        \\  leaf(2)
        \\  leaf(1)
    );
}
