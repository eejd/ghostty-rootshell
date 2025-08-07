const std = @import("std");
const assert = std.debug.assert;
const build_config = @import("../build_config.zig");
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
/// Optionally the following functions can also be implemented:
///
///   - `fn splitTreeLabel(*const View) []const u8` - Return a label that is used
///     for the debug view. If this isn't specified then the node handle
///     will be used.
///
/// Note: for both the ref and unref functions, the allocator is optional.
/// If the functions take less arguments, then the allocator will not be
/// passed.
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
            nodes[0] = .{ .leaf = try viewRef(view, gpa) };
            errdefer viewUnref(view, gpa);

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
                    .leaf => |view| viewUnref(view, gpa),
                    .split => {},
                };
                self.arena.deinit();
            }

            self.* = undefined;
        }

        /// Clone this tree, returning a new tree with the same nodes.
        pub fn clone(self: *const Self, gpa: Allocator) Allocator.Error!Self {
            // Create a new arena allocator for the clone.
            var arena = ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();

            // Allocate a new nodes array and copy the existing nodes into it.
            const nodes = try alloc.dupe(Node, self.nodes);

            // Increase the reference count of all the views in the nodes.
            try refNodes(gpa, nodes);

            return .{
                .arena = arena,
                .nodes = nodes,
            };
        }

        /// Returns true if this is an empty tree.
        pub fn isEmpty(self: *const Self) bool {
            // An empty tree has no nodes.
            return self.nodes.len == 0;
        }

        /// An iterator over all the views in the tree.
        pub fn iterator(
            self: *const Self,
        ) Iterator {
            return .{ .nodes = self.nodes };
        }

        pub const Iterator = struct {
            i: Node.Handle = 0,
            nodes: []const Node,

            pub const Entry = struct {
                handle: Node.Handle,
                view: *View,
            };

            pub fn next(self: *Iterator) ?Entry {
                // If we have no nodes, return null.
                if (self.i >= self.nodes.len) return null;

                // Get the current node and increment the index.
                const handle = self.i;
                self.i += 1;
                const node = self.nodes[handle];

                return switch (node) {
                    .leaf => |v| .{ .handle = handle, .view = v },
                    .split => self.next(),
                };
            }
        };

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
            try refNodes(gpa, nodes);

            return .{ .arena = arena, .nodes = nodes };
        }

        /// Remove a node from the tree.
        pub fn remove(
            self: *Self,
            gpa: Allocator,
            at: Node.Handle,
        ) Allocator.Error!Self {
            assert(at < self.nodes.len);

            // If we're removing node zero then we're clearing the tree.
            if (at == 0) return .empty;

            // The new arena for our new tree.
            var arena = ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();

            // Allocate our new nodes list with the number of nodes we'll
            // need after the removal.
            const nodes = try alloc.alloc(Node, self.countAfterRemoval(
                0,
                at,
                0,
            ));

            // Traverse the tree and copy all our nodes into place.
            assert(self.removeNode(
                nodes,
                0,
                0,
                at,
            ) > 0);

            // Increase the reference count of all the nodes.
            try refNodes(gpa, nodes);

            return .{
                .arena = arena,
                .nodes = nodes,
            };
        }

        fn removeNode(
            self: *Self,
            nodes: []Node,
            new_offset: Node.Handle,
            current: Node.Handle,
            target: Node.Handle,
        ) Node.Handle {
            assert(current != target);

            switch (self.nodes[current]) {
                // Leaf is simple, just copy it over. We don't ref anything
                // yet because it'd make undo (errdefer) harder. We do that
                // all at once later.
                .leaf => |view| {
                    nodes[new_offset] = .{ .leaf = view };
                    return 1;
                },

                .split => |s| {
                    // If we're removing one of the split node sides then
                    // we remove the split node itself as well and only add
                    // the other (non-removed) side.
                    if (s.left == target) return self.removeNode(
                        nodes,
                        new_offset,
                        s.right,
                        target,
                    );
                    if (s.right == target) return self.removeNode(
                        nodes,
                        new_offset,
                        s.left,
                        target,
                    );

                    // Neither side is being directly removed, so we traverse.
                    const left = self.removeNode(
                        nodes,
                        new_offset + 1,
                        s.left,
                        target,
                    );
                    assert(left > 0);
                    const right = self.removeNode(
                        nodes,
                        new_offset + 1 + left,
                        s.right,
                        target,
                    );
                    assert(right > 0);
                    nodes[new_offset] = .{ .split = .{
                        .layout = s.layout,
                        .ratio = s.ratio,
                        .left = new_offset + 1,
                        .right = new_offset + 1 + left,
                    } };

                    return left + right + 1;
                },
            }
        }

        /// Returns the number of nodes that would be needed to store
        /// the tree if the target node is removed.
        fn countAfterRemoval(
            self: *Self,
            current: Node.Handle,
            target: Node.Handle,
            acc: usize,
        ) usize {
            assert(current != target);

            return switch (self.nodes[current]) {
                // Leaf is simple, always takes one node.
                .leaf => acc + 1,

                // Split is slightly more complicated. If either side is the
                // target to remove, then we remove the split node as well
                // so our count is just the count of the other side.
                //
                // If neither side is the target, then we count both sides
                // and add one to account for the split node itself.
                .split => |s| if (s.left == target) self.countAfterRemoval(
                    s.right,
                    target,
                    acc,
                ) else if (s.right == target) self.countAfterRemoval(
                    s.left,
                    target,
                    acc,
                ) else self.countAfterRemoval(
                    s.left,
                    target,
                    acc,
                ) + self.countAfterRemoval(
                    s.right,
                    target,
                    acc,
                ) + 1,
            };
        }

        /// Reference all the nodes in the given slice, handling unref if
        /// any fail. This should be called LAST so you don't have to undo
        /// the refs at any further point after this.
        fn refNodes(gpa: Allocator, nodes: []Node) Allocator.Error!void {
            // We need to increase the reference count of all the nodes.
            // Careful accounting here so that we properly unref on error
            // only the nodes we referenced.
            var reffed: usize = 0;
            errdefer for (0..reffed) |i| {
                switch (nodes[i]) {
                    .split => {},
                    .leaf => |view| viewUnref(view, gpa),
                }
            };
            for (0..nodes.len) |i| {
                switch (nodes[i]) {
                    .split => {},
                    .leaf => |view| nodes[i] = .{ .leaf = try viewRef(view, gpa) },
                }
                reffed = i;
            }
            assert(reffed == nodes.len - 1);
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
                .width = @floatFromInt(dim.width),
                .height = @floatFromInt(dim.height),
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
                return;
            }

            // Use our arena's GPA to allocate some intermediate memory.
            // Requiring allocation for formatting is nasty but this is really
            // only used for debugging and testing and shouldn't hit OOM
            // scenarios.
            var arena: ArenaAllocator = .init(self.arena.child_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Get our spatial representation.
            const sp = try self.spatial(alloc);

            // The width we need for the largest label.
            const max_label_width: usize = max_label_width: {
                if (!@hasDecl(View, "splitTreeLabel")) {
                    break :max_label_width std.math.log10(sp.slots.len) + 1;
                }

                var max: usize = 0;
                for (self.nodes) |node| switch (node) {
                    .split => {},
                    .leaf => |view| {
                        const label = view.splitTreeLabel();
                        max = @max(max, label.len);
                    },
                };

                break :max_label_width max;
            };

            // We need space for whitespace and ASCII art so add that.
            // We need to accommodate the leaf handle, whitespace, and
            // then the border.
            const cell_width = cell_width: {
                // Border + whitespace + label + whitespace + border.
                break :cell_width 2 + max_label_width + 2;
            };
            const cell_height = cell_height: {
                // Border + label + border. No whitespace needed on the
                // vertical axis.
                break :cell_height 1 + 1 + 1;
            };

            // Make a grid that can fit our entire ASCII diagram. We know
            // the width/height based on node 0.
            const grid = grid: {
                // Get our initial width/height. Each leaf is 1x1 in this.
                var width: usize = @intFromFloat(@ceil(sp.slots[0].width));
                var height: usize = @intFromFloat(@ceil(sp.slots[0].height));

                // We need space for whitespace and ASCII art so add that.
                // We need to accommodate the leaf handle, whitespace, and
                // then the border.
                width *= cell_width;
                height *= cell_height;

                const rows = try alloc.alloc([]u8, height);
                for (0..rows.len) |y| {
                    rows[y] = try alloc.alloc(u8, width + 1);
                    @memset(rows[y], ' ');
                    rows[y][width] = '\n';
                }
                break :grid rows;
            };

            // Draw each node
            for (sp.slots, 0..) |slot, handle| {
                // We only draw leaf nodes. Splits are only used for layout.
                const node = self.nodes[handle];
                switch (node) {
                    .leaf => {},
                    .split => continue,
                }

                var x: usize = @intFromFloat(@ceil(slot.x));
                var y: usize = @intFromFloat(@ceil(slot.y));
                var width: usize = @intFromFloat(@ceil(slot.width));
                var height: usize = @intFromFloat(@ceil(slot.height));
                x *= cell_width;
                y *= cell_height;
                width *= cell_width;
                height *= cell_height;

                // Top border
                {
                    const top = grid[y][x..][0..width];
                    top[0] = '+';
                    for (1..width - 1) |i| top[i] = '-';
                    top[width - 1] = '+';
                }

                // Bottom border
                {
                    const bottom = grid[y + height - 1][x..][0..width];
                    bottom[0] = '+';
                    for (1..width - 1) |i| bottom[i] = '-';
                    bottom[width - 1] = '+';
                }

                // Left border
                for (y + 1..y + height - 1) |y_cur| grid[y_cur][x] = '|';
                for (y + 1..y + height - 1) |y_cur| grid[y_cur][x + width - 1] = '|';

                // Get our label text
                var buf: [10]u8 = undefined;
                const label: []const u8 = if (@hasDecl(View, "splitTreeLabel"))
                    node.leaf.splitTreeLabel()
                else
                    try std.fmt.bufPrint(&buf, "{d}", .{handle});

                // Draw the handle in the center
                const x_mid = width / 2 + x;
                const y_mid = height / 2 + y;
                const label_width = label.len;
                const label_start = x_mid - label_width / 2;
                const row = grid[y_mid][label_start..];
                _ = try std.fmt.bufPrint(row, "{s}", .{label});
            }

            // Output every row
            for (grid) |row| {
                try writer.writeAll(row);
            }
        }

        fn viewRef(view: *View, gpa: Allocator) Allocator.Error!*View {
            const func = @typeInfo(@TypeOf(View.ref)).@"fn";
            return switch (func.params.len) {
                1 => view.ref(),
                2 => try view.ref(gpa),
                else => @compileError("invalid view ref function"),
            };
        }

        fn viewUnref(view: *View, gpa: Allocator) void {
            const func = @typeInfo(@TypeOf(View.unref)).@"fn";
            switch (func.params.len) {
                1 => view.unref(),
                2 => view.unref(gpa),
                else => @compileError("invalid view unref function"),
            }
        }

        /// Make this a valid gobject if we're in a GTK environment.
        pub const getGObjectType = switch (build_config.app_runtime) {
            .gtk, .@"gtk-ng" => @import("gobject").ext.defineBoxed(
                Self,
                .{
                    // To get the type name we get the non-qualified type name
                    // of the view and append that to `GhosttySplitTree`.
                    .name = name: {
                        const type_name = @typeName(View);
                        const last = if (std.mem.lastIndexOfScalar(
                            u8,
                            type_name,
                            '.',
                        )) |idx|
                            type_name[idx + 1 ..]
                        else
                            type_name;
                        assert(last.len > 0);
                        break :name "GhosttySplitTree" ++ last;
                    },

                    .funcs = .{
                        .copy = &struct {
                            fn copy(self: *Self) callconv(.c) *Self {
                                const ptr = @import("glib").ext.create(Self);
                                const alloc = self.arena.child_allocator;
                                ptr.* = self.clone(alloc) catch @panic("oom");
                                return ptr;
                            }
                        }.copy,
                        .free = &struct {
                            fn free(self: *Self) callconv(.c) void {
                                self.deinit();
                                @import("glib").ext.destroy(self);
                            }
                        }.free,
                    },
                },
            ),

            .none => void,
        };
    };
}

const TestTree = SplitTree(TestView);

const TestView = struct {
    const Self = @This();

    label: []const u8,

    pub fn ref(self: *Self, alloc: Allocator) Allocator.Error!*Self {
        const ptr = try alloc.create(Self);
        ptr.* = self.*;
        return ptr;
    }

    pub fn unref(self: *Self, alloc: Allocator) void {
        alloc.destroy(self);
    }

    pub fn splitTreeLabel(self: *const Self) []const u8 {
        return self.label;
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
    var v: TestTree.View = .{ .label = "A" };
    var t: TestTree = try .init(alloc, &v);
    defer t.deinit();

    const str = try std.fmt.allocPrint(alloc, "{}", .{t});
    defer alloc.free(str);
    try testing.expectEqualStrings(str,
        \\+---+
        \\| A |
        \\+---+
        \\
    );
}

test "SplitTree: split horizontal" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
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
        \\+---++---+
        \\| A || B |
        \\+---++---+
        \\
    );
}

test "SplitTree: split vertical" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();

    var t3 = try t1.split(
        alloc,
        0, // at root
        .down, // split down
        &t2, // insert t2
    );
    defer t3.deinit();

    const str = try std.fmt.allocPrint(alloc, "{}", .{t3});
    defer alloc.free(str);
    try testing.expectEqualStrings(str,
        \\+---+
        \\| A |
        \\+---+
        \\+---+
        \\| B |
        \\+---+
        \\
    );
}

test "SplitTree: remove leaf" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var t3 = try t1.split(
        alloc,
        0, // at root
        .right, // split right
        &t2, // insert t2
    );
    defer t3.deinit();

    // Remove "A"
    var it = t3.iterator();
    var t4 = try t3.remove(
        alloc,
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "A")) {
                break entry.handle;
            }
        } else return error.NotFound,
    );
    defer t4.deinit();

    const str = try std.fmt.allocPrint(alloc, "{}", .{t4});
    defer alloc.free(str);
    try testing.expectEqualStrings(str,
        \\+---+
        \\| B |
        \\+---+
        \\
    );
}

test "SplitTree: split twice, remove intermediary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var v3: TestTree.View = .{ .label = "C" };
    var t3: TestTree = try .init(alloc, &v3);
    defer t3.deinit();

    // A | B horizontal.
    var split1 = try t1.split(
        alloc,
        0, // at root
        .right, // split right
        &t2, // insert t2
    );
    defer split1.deinit();

    // Insert C below that.
    var split2 = try split1.split(
        alloc,
        0, // at root
        .down, // split down
        &t3, // insert t3
    );
    defer split2.deinit();

    {
        const str = try std.fmt.allocPrint(alloc, "{}", .{split2});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---++---+
            \\| A || B |
            \\+---++---+
            \\+--------+
            \\|    C   |
            \\+--------+
            \\
        );
    }

    // Remove "B"
    var it = split2.iterator();
    var split3 = try split2.remove(
        alloc,
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "B")) {
                break entry.handle;
            }
        } else return error.NotFound,
    );
    defer split3.deinit();

    {
        const str = try std.fmt.allocPrint(alloc, "{}", .{split3});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---+
            \\| A |
            \\+---+
            \\+---+
            \\| C |
            \\+---+
            \\
        );
    }

    // Remove every node from split2 (our most complex one), which should
    // never crash. We don't test the result is correct, this just verifies
    // we don't hit any assertion failures.
    for (0..split2.nodes.len) |i| {
        var t = try split2.remove(alloc, @intCast(i));
        t.deinit();
    }
}
