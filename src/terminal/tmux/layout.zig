const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const assert = @import("../../quirks.zig").inlineAssert;
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

const log = std.log.scoped(.terminal_tmux);

/// A tmux layout.
///
/// This is a tree structure so by definition it pretty much needs to be
/// allocated. We leave allocation up to the user of this struct, but
/// a general recommendation is to use an arena allocator for simplicity
/// in freeing the entire layout at once.
pub const Layout = struct {
    /// Width, height of the node
    width: usize,
    height: usize,

    /// X and Y offset from the top-left corner of the window.
    x: usize,
    y: usize,

    /// The content of this node, either a pane (leaf) or more nodes
    /// (split) horizontally or vertically.
    content: Content,

    pub const Content = union(enum) {
        pane: usize,
        horizontal: []const Layout,
        vertical: []const Layout,
    };

    pub const ParseError = Allocator.Error || error{SyntaxError};

    /// Parse a layout string that includes a 4-character checksum prefix.
    ///
    /// The expected format is: `XXXX,layout_string` where XXXX is the
    /// 4-character hexadecimal checksum and the layout string follows
    /// after the comma. For example: `f8f9,80x24,0,0{40x24,0,0,1,40x24,40,0,2}`.
    ///
    /// Returns `ChecksumMismatch` if the checksum doesn't match the layout.
    /// Returns `SyntaxError` if the format is invalid.
    pub fn parseWithChecksum(
        alloc: Allocator,
        str: []const u8,
    ) (ParseError || error{ChecksumMismatch})!Layout {
        // If the string is less than 5 characters, it can't possibly
        // be correct. 4-char checksum + comma. In practice it should
        // be even longer, but that'll fail parse later.
        if (str.len < 5) return error.SyntaxError;
        if (str[4] != ',') return error.SyntaxError;

        // The layout string should start with a 4-character checksum.
        const checksum: Checksum = .calculate(str[5..]);
        if (!std.mem.startsWith(
            u8,
            str,
            &checksum.asString(),
        )) return error.ChecksumMismatch;

        // Checksum matches, parse the rest.
        return try parse(alloc, str[5..]);
    }

    /// Parse a layout string into a Layout structure. The given allocator
    /// will be used for all allocations within the layout. Note that
    /// individual nodes can't be freed so this allocator must be some
    /// kind of arena allocator.
    ///
    /// The layout string must be fully provided as a single string.
    /// Layouts are generally small so this should not be a problem.
    ///
    /// Tmux layout strings have the following format:
    ///
    /// - WxH,X,Y,ID Leaf pane: width×height, x-offset, y-offset, pane ID
    /// - WxH,X,Y{...} Horizontal split (left-right), children comma-separated
    /// - WxH,X,Y[...] Vertical split (top-bottom), children comma-separated
    pub fn parse(alloc: Allocator, str: []const u8) ParseError!Layout {
        var offset: usize = 0;
        const root = try parseNext(
            alloc,
            str,
            &offset,
        );
        if (offset != str.len) return error.SyntaxError;
        return root;
    }

    fn parseNext(
        alloc: Allocator,
        str: []const u8,
        offset: *usize,
    ) ParseError!Layout {
        // Find the first `x` to grab the width.
        const width: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            'x',
        )) |idx| width: {
            defer offset.* += idx + 1; // Consume `x`
            break :width std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Find the height, up to a comma.
        const height: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            ',',
        )) |idx| height: {
            defer offset.* += idx + 1; // Consume `,`
            break :height std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Find X
        const x: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            ',',
        )) |idx| x: {
            defer offset.* += idx + 1; // Consume `,`
            break :x std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Find Y, which can end in any of `,{,[`
        const y: usize = if (std.mem.indexOfAny(
            u8,
            str[offset.*..],
            ",{[",
        )) |idx| y: {
            defer offset.* += idx; // Don't consume the delimiter!
            break :y std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Determine our child node.
        const content: Layout.Content = switch (str[offset.*]) {
            ',' => content: {
                // Consume the delimiter
                offset.* += 1;

                // Leaf pane. Read up to `,}]` because we may be in
                // a set of nodes. If none exist, end of string is fine.
                const idx = std.mem.indexOfAny(
                    u8,
                    str[offset.*..],
                    ",}]",
                ) orelse str.len - offset.*;

                defer offset.* += idx; // Consume the pane ID, not the delimiter
                const pane_id = std.fmt.parseInt(
                    usize,
                    str[offset.* .. offset.* + idx],
                    10,
                ) catch return error.SyntaxError;

                break :content .{ .pane = pane_id };
            },

            '{', '[' => |opening| content: {
                var nodes: std.ArrayList(Layout) = .empty;
                defer nodes.deinit(alloc);

                // Move beyond our opening
                offset.* += 1;

                while (true) {
                    try nodes.append(alloc, try parseNext(
                        alloc,
                        str,
                        offset,
                    ));

                    // We should not reach the end of string here because
                    // we expect a closing bracket.
                    if (offset.* >= str.len) return error.SyntaxError;

                    // If it is a comma, we expect another node.
                    if (str[offset.*] == ',') {
                        offset.* += 1; // Consume
                        continue;
                    }

                    // We expect a closing bracket now.
                    switch (opening) {
                        '{' => if (str[offset.*] != '}') return error.SyntaxError,
                        '[' => if (str[offset.*] != ']') return error.SyntaxError,
                        else => return error.SyntaxError,
                    }

                    // Successfully parsed all children.
                    offset.* += 1; // Consume closing bracket
                    break :content switch (opening) {
                        '{' => .{ .horizontal = try nodes.toOwnedSlice(alloc) },
                        '[' => .{ .vertical = try nodes.toOwnedSlice(alloc) },
                        else => unreachable,
                    };
                }
            },

            // indexOfAny above guarantees we have only the above
            else => unreachable,
        };

        return .{
            .width = width,
            .height = height,
            .x = x,
            .y = y,
            .content = content,
        };
    }

    /// Build a `SplitTree(V)` from this tmux layout tree. Converts
    /// N-ary tmux splits into right-nested binary splits with ratios
    /// derived from the tmux geometry.
    ///
    /// The `Resolver` type must provide a `resolve` method:
    ///
    ///   fn resolve(*const Resolver, pane_id: usize) ?*V
    ///
    /// This is called for each leaf pane to obtain the view pointer.
    /// If any pane cannot be resolved, returns `SplitTree(V).empty`.
    ///
    /// The returned tree holds refs on the views; the caller must
    /// call `deinit()` to release them.
    pub fn buildSplitTree(
        self: Layout,
        comptime V: type,
        gpa: Allocator,
        resolver: anytype,
    ) Allocator.Error!SplitTree(V) {
        const Tree = SplitTree(V);
        const node_count = countTreeNodes(self);
        if (node_count == 0) return Tree.empty;

        var arena: ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const nodes = try alloc.alloc(Tree.Node, node_count);

        const next = fillLayoutNode(V, self, nodes, 0, resolver) orelse {
            // A leaf pane was not found in the resolver. This is a
            // normal condition (pane not yet created), not an error.
            // Deinit the arena explicitly since errdefer won't fire.
            arena.deinit();
            return Tree.empty;
        };
        assert(next == node_count);

        // Ref all leaf views. SplitTree owns refs and will unref
        // on deinit. Handle both 1-param and 2-param ref functions.
        for (nodes) |*node| {
            switch (node.*) {
                .leaf => |view| {
                    const func = @typeInfo(@TypeOf(V.ref)).@"fn";
                    const reffed = switch (func.params.len) {
                        1 => view.ref(),
                        2 => try view.ref(gpa),
                        else => @compileError("invalid view ref function"),
                    };
                    node.* = .{ .leaf = reffed };
                },
                .split => {},
            }
        }

        return .{
            .arena = arena,
            .nodes = nodes,
            .zoomed = null,
        };
    }

    /// Count the total number of SplitTree nodes needed to represent
    /// a layout as a binary tree. Each leaf pane = 1 node. Each
    /// N-ary split = (N-1) split nodes + sum of child subtrees.
    fn countTreeNodes(layout: Layout) usize {
        return switch (layout.content) {
            .pane => 1,
            .horizontal, .vertical => |children| countChildrenNodes(children),
        };
    }

    fn countChildrenNodes(children: []const Layout) usize {
        if (children.len == 0) return 0;
        if (children.len == 1) return countTreeNodes(children[0]);

        // One split node for this level, plus nodes for left child
        // and nodes for the right subtree (remaining children).
        return 1 + countTreeNodes(children[0]) + countChildrenNodes(children[1..]);
    }

    /// Recursively fill nodes array for a layout. Returns the
    /// next free index, or null if a required pane view is missing.
    fn fillLayoutNode(
        comptime V: type,
        layout: Layout,
        nodes: []SplitTree(V).Node,
        idx: usize,
        resolver: anytype,
    ) ?usize {
        return switch (layout.content) {
            .pane => |pane_id| {
                const view = resolver.resolve(pane_id) orelse {
                    log.warn("buildSplitTree: layout references unknown pane {}", .{pane_id});
                    return null;
                };
                nodes[idx] = .{ .leaf = view };
                return idx + 1;
            },
            .horizontal => |children| fillChildrenNodes(V, .horizontal, children, nodes, idx, resolver),
            .vertical => |children| fillChildrenNodes(V, .vertical, children, nodes, idx, resolver),
        };
    }

    /// Fill nodes for an N-ary split, converting to right-nested
    /// binary splits. The split ratio at each level is computed from
    /// the tmux geometry (width for horizontal, height for vertical).
    fn fillChildrenNodes(
        comptime V: type,
        direction: SplitTree(V).Split.Layout,
        children: []const Layout,
        nodes: []SplitTree(V).Node,
        idx: usize,
        resolver: anytype,
    ) ?usize {
        if (children.len == 0) return idx;
        if (children.len == 1) return fillLayoutNode(V, children[0], nodes, idx, resolver);

        // Binary split: left = children[0], right = rest.
        // Place split node at idx, left subtree at idx+1, right
        // subtree immediately after left.
        const left_start = idx + 1;
        const right_start = fillLayoutNode(V, children[0], nodes, left_start, resolver) orelse
            return null;
        const next = fillChildrenNodes(V, direction, children[1..], nodes, right_start, resolver) orelse
            return null;

        // Compute ratio from tmux geometry. For horizontal splits,
        // use width; for vertical, use height.
        const ratio: f16 = computeSplitRatio(direction == .horizontal, children);

        nodes[idx] = .{ .split = .{
            .layout = direction,
            .ratio = ratio,
            .left = @enumFromInt(left_start),
            .right = @enumFromInt(right_start),
        } };

        return next;
    }

    /// Compute the ratio of the first child relative to the total
    /// dimension of all children in the slice. Returns 0.5 as a
    /// fallback if the total is zero.
    fn computeSplitRatio(
        use_width: bool,
        children: []const Layout,
    ) f16 {
        if (children.len < 2) return 0.5;

        var total: usize = 0;
        for (children) |child| {
            total += if (use_width) child.width else child.height;
        }

        if (total == 0) return 0.5;

        const first_dim: usize = if (use_width) children[0].width else children[0].height;

        return @floatCast(@as(f64, @floatFromInt(first_dim)) / @as(f64, @floatFromInt(total)));
    }

    /// Deep-copy a layout tree onto a new allocator. All child slices
    /// are duplicated so the returned tree is fully independent of the
    /// original's backing memory.
    pub fn clone(self: Layout, alloc: Allocator) Allocator.Error!Layout {
        return .{
            .width = self.width,
            .height = self.height,
            .x = self.x,
            .y = self.y,
            .content = switch (self.content) {
                .pane => |id| .{ .pane = id },
                inline .horizontal, .vertical => |children, tag| content: {
                    const cloned = try alloc.alloc(Layout, children.len);
                    for (children, 0..) |child, i| {
                        cloned[i] = try child.clone(alloc);
                    }
                    break :content @unionInit(Content, @tagName(tag), cloned);
                },
            },
        };
    }
};

pub const Checksum = enum(u16) {
    _,

    /// Calculate the checksum of a tmux layout string.
    /// The algorithm rotates the checksum right by 1 bit (with wraparound)
    /// and adds the ASCII value of each character.
    pub fn calculate(str: []const u8) Checksum {
        var result: u16 = 0;
        for (str) |c| {
            // Rotate right by 1: (result >> 1) + ((result & 1) << 15)
            result = (result >> 1) | ((result & 1) << 15);
            result +%= c;
        }

        return @enumFromInt(result);
    }

    /// Convert the checksum to a 4-character hexadecimal string. This
    /// is always zero-padded to match the tmux implementation
    /// (in layout-custom.c).
    pub fn asString(self: Checksum) [4]u8 {
        const value = @intFromEnum(self);
        const charset = "0123456789abcdef";
        return .{
            charset[(value >> 12) & 0xf],
            charset[(value >> 8) & 0xf],
            charset[(value >> 4) & 0xf],
            charset[value & 0xf],
        };
    }
};

test "simple single pane" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0,42");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    try testing.expectEqual(0, layout.x);
    try testing.expectEqual(0, layout.y);
    try testing.expectEqual(42, layout.content.pane);
}

test "single pane with offset" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "40x12,10,5,7");
    try testing.expectEqual(40, layout.width);
    try testing.expectEqual(12, layout.height);
    try testing.expectEqual(10, layout.x);
    try testing.expectEqual(5, layout.y);
    try testing.expectEqual(7, layout.content.pane);
}

test "single pane large values" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "1920x1080,100,200,999");
    try testing.expectEqual(1920, layout.width);
    try testing.expectEqual(1080, layout.height);
    try testing.expectEqual(100, layout.x);
    try testing.expectEqual(200, layout.y);
    try testing.expectEqual(999, layout.content.pane);
}

test "horizontal split two panes" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    try testing.expectEqual(0, layout.x);
    try testing.expectEqual(0, layout.y);

    const children = layout.content.horizontal;
    try testing.expectEqual(2, children.len);

    try testing.expectEqual(40, children[0].width);
    try testing.expectEqual(24, children[0].height);
    try testing.expectEqual(0, children[0].x);
    try testing.expectEqual(0, children[0].y);
    try testing.expectEqual(1, children[0].content.pane);

    try testing.expectEqual(40, children[1].width);
    try testing.expectEqual(24, children[1].height);
    try testing.expectEqual(40, children[1].x);
    try testing.expectEqual(0, children[1].y);
    try testing.expectEqual(2, children[1].content.pane);
}

test "vertical split two panes" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0[80x12,0,0,1,80x12,0,12,2]");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    try testing.expectEqual(0, layout.x);
    try testing.expectEqual(0, layout.y);

    const children = layout.content.vertical;
    try testing.expectEqual(2, children.len);

    try testing.expectEqual(80, children[0].width);
    try testing.expectEqual(12, children[0].height);
    try testing.expectEqual(0, children[0].x);
    try testing.expectEqual(0, children[0].y);
    try testing.expectEqual(1, children[0].content.pane);

    try testing.expectEqual(80, children[1].width);
    try testing.expectEqual(12, children[1].height);
    try testing.expectEqual(0, children[1].x);
    try testing.expectEqual(12, children[1].y);
    try testing.expectEqual(2, children[1].content.pane);
}

test "horizontal split three panes" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "120x24,0,0{40x24,0,0,1,40x24,40,0,2,40x24,80,0,3}");
    try testing.expectEqual(120, layout.width);
    try testing.expectEqual(24, layout.height);

    const children = layout.content.horizontal;
    try testing.expectEqual(3, children.len);
    try testing.expectEqual(1, children[0].content.pane);
    try testing.expectEqual(2, children[1].content.pane);
    try testing.expectEqual(3, children[2].content.pane);
}

test "nested horizontal in vertical" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Vertical split with top pane and bottom horizontal split
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0[80x12,0,0,1,80x12,0,12{40x12,0,12,2,40x12,40,12,3}]");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);

    const vert_children = layout.content.vertical;
    try testing.expectEqual(2, vert_children.len);

    // First child is a simple pane
    try testing.expectEqual(1, vert_children[0].content.pane);

    // Second child is a horizontal split
    const horiz_children = vert_children[1].content.horizontal;
    try testing.expectEqual(2, horiz_children.len);
    try testing.expectEqual(2, horiz_children[0].content.pane);
    try testing.expectEqual(3, horiz_children[1].content.pane);
}

test "nested vertical in horizontal" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Horizontal split with left pane and right vertical split
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0,1,40x24,40,0[40x12,40,0,2,40x12,40,12,3]}");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);

    const horiz_children = layout.content.horizontal;
    try testing.expectEqual(2, horiz_children.len);

    // First child is a simple pane
    try testing.expectEqual(1, horiz_children[0].content.pane);

    // Second child is a vertical split
    const vert_children = horiz_children[1].content.vertical;
    try testing.expectEqual(2, vert_children.len);
    try testing.expectEqual(2, vert_children[0].content.pane);
    try testing.expectEqual(3, vert_children[1].content.pane);
}

test "deeply nested layout" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Three levels deep
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0[40x12,0,0,1,40x12,0,12,2],40x24,40,0,3}");

    const horiz = layout.content.horizontal;
    try testing.expectEqual(2, horiz.len);

    const vert = horiz[0].content.vertical;
    try testing.expectEqual(2, vert.len);
    try testing.expectEqual(1, vert[0].content.pane);
    try testing.expectEqual(2, vert[1].content.pane);

    try testing.expectEqual(3, horiz[1].content.pane);
}

test "syntax error empty string" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), ""));
}

test "syntax error missing width" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "x24,0,0,1"));
}

test "syntax error missing height" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x,0,0,1"));
}

test "syntax error missing x" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,,0,1"));
}

test "syntax error missing y" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,,1"));
}

test "syntax error missing pane id" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0,"));
}

test "syntax error non-numeric width" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "abcx24,0,0,1"));
}

test "syntax error non-numeric pane id" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0,abc"));
}

test "syntax error unclosed horizontal bracket" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0{40x24,0,0,1"));
}

test "syntax error unclosed vertical bracket" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0[40x24,0,0,1"));
}

test "syntax error mismatched brackets" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0{40x24,0,0,1]"));
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0[40x24,0,0,1}"));
}

test "syntax error trailing data" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0,1extra"));
}

test "syntax error no x separator" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "8024,0,0,1"));
}

test "syntax error no content delimiter" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0"));
}

// parseWithChecksum tests

test "parseWithChecksum valid" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parseWithChecksum(arena.allocator(), "f8f9,80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
}

test "parseWithChecksum mismatch" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.ChecksumMismatch, Layout.parseWithChecksum(arena.allocator(), "0000,80x24,0,0{40x24,0,0,1,40x24,40,0,2}"));
}

test "parseWithChecksum too short" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parseWithChecksum(arena.allocator(), "bb62"));
    try testing.expectError(error.SyntaxError, Layout.parseWithChecksum(arena.allocator(), ""));
}

test "parseWithChecksum missing comma" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parseWithChecksum(arena.allocator(), "bb62x159x48,0,0"));
}

// Checksum tests

test "checksum empty string" {
    const checksum = Checksum.calculate("");
    try testing.expectEqual(@as(u16, 0), @intFromEnum(checksum));
    try testing.expectEqualStrings("0000", &checksum.asString());
}

test "checksum single character" {
    // 'A' = 65, first iteration: csum = 0 >> 1 | 0 = 0, then 0 + 65 = 65
    const checksum = Checksum.calculate("A");
    try testing.expectEqual(@as(u16, 65), @intFromEnum(checksum));
    try testing.expectEqualStrings("0041", &checksum.asString());
}

test "checksum two characters" {
    // 'A' (65): csum = 0, rotate = 0, add 65 => 65
    // 'B' (66): csum = 65, rotate => (65 >> 1) | ((65 & 1) << 15) = 32 | 32768 = 32800
    //           add 66 => 32800 + 66 = 32866
    const checksum = Checksum.calculate("AB");
    try testing.expectEqual(@as(u16, 32866), @intFromEnum(checksum));
    try testing.expectEqualStrings("8062", &checksum.asString());
}

test "checksum simple layout" {
    const checksum = Checksum.calculate("80x24,0,0,42");
    try testing.expectEqualStrings("d962", &checksum.asString());
}

test "checksum horizontal split layout" {
    const checksum = Checksum.calculate("80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    try testing.expectEqualStrings("f8f9", &checksum.asString());
}

test "checksum asString zero padding" {
    // Value 0x000f should produce "000f"
    const checksum: Checksum = @enumFromInt(0x000f);
    try testing.expectEqualStrings("000f", &checksum.asString());
}

test "checksum asString all digits" {
    // Value 0x1234 should produce "1234"
    const checksum: Checksum = @enumFromInt(0x1234);
    try testing.expectEqualStrings("1234", &checksum.asString());
}

test "checksum asString with letters" {
    // Value 0xabcd should produce "abcd"
    const checksum: Checksum = @enumFromInt(0xabcd);
    try testing.expectEqualStrings("abcd", &checksum.asString());
}

test "checksum asString max value" {
    // Value 0xffff should produce "ffff"
    const checksum: Checksum = @enumFromInt(0xffff);
    try testing.expectEqualStrings("ffff", &checksum.asString());
}

test "checksum wraparound" {
    const checksum = Checksum.calculate("\xff\xff\xff\xff\xff\xff\xff\xff");
    try testing.expectEqualStrings("03fc", &checksum.asString());
}

test "checksum deterministic" {
    // Same input should always produce same output
    const str = "159x48,0,0{79x48,0,0,79x48,80,0}";
    const checksum1 = Checksum.calculate(str);
    const checksum2 = Checksum.calculate(str);
    try testing.expectEqual(checksum1, checksum2);
}

test "checksum different inputs different outputs" {
    const checksum1 = Checksum.calculate("80x24,0,0,1");
    const checksum2 = Checksum.calculate("80x24,0,0,2");
    try testing.expect(@intFromEnum(checksum1) != @intFromEnum(checksum2));
}

test "checksum known tmux layout bb62" {
    // From tmux documentation: "bb62,159x48,0,0{79x48,0,0,79x48,80,0}"
    // The checksum "bb62" corresponds to the layout "159x48,0,0{79x48,0,0,79x48,80,0}"
    const checksum = Checksum.calculate("159x48,0,0{79x48,0,0,79x48,80,0}");
    try testing.expectEqualStrings("bb62", &checksum.asString());
}

test "clone preserves leaf" {
    var src_arena: ArenaAllocator = .init(testing.allocator);
    defer src_arena.deinit();
    const original: Layout = try .parse(src_arena.allocator(), "80x24,0,0,42");

    var dst_arena: ArenaAllocator = .init(testing.allocator);
    defer dst_arena.deinit();
    const cloned = try original.clone(dst_arena.allocator());

    try testing.expectEqual(original.width, cloned.width);
    try testing.expectEqual(original.height, cloned.height);
    try testing.expectEqual(original.x, cloned.x);
    try testing.expectEqual(original.y, cloned.y);
    try testing.expectEqual(original.content.pane, cloned.content.pane);
}

test "clone deep copies split tree" {
    var src_arena: ArenaAllocator = .init(testing.allocator);
    defer src_arena.deinit();

    // Nested layout: vertical split containing a horizontal split
    const original: Layout = try .parse(
        src_arena.allocator(),
        "80x24,0,0[80x12,0,0{40x12,0,0,1,40x12,40,0,2},80x12,0,12,3]",
    );

    var dst_arena: ArenaAllocator = .init(testing.allocator);
    defer dst_arena.deinit();
    const cloned = try original.clone(dst_arena.allocator());

    // Verify structure
    const children = cloned.content.vertical;
    try testing.expectEqual(2, children.len);

    // First child is a horizontal split
    const horiz = children[0].content.horizontal;
    try testing.expectEqual(2, horiz.len);
    try testing.expectEqual(1, horiz[0].content.pane);
    try testing.expectEqual(2, horiz[1].content.pane);

    // Second child is a leaf
    try testing.expectEqual(3, children[1].content.pane);

    // Verify cloned children are on a different allocation (not aliased)
    try testing.expect(cloned.content.vertical.ptr != original.content.vertical.ptr);
}

/// Minimal view type for testing buildSplitTree. Implements the
/// ref/unref/eql contract required by SplitTree.
const TestView = struct {
    id: usize,
    ref_count: usize = 1,

    pub fn ref(self: *TestView) *TestView {
        self.ref_count += 1;
        return self;
    }

    pub fn unref(self: *TestView) void {
        self.ref_count -= 1;
    }

    pub fn eql(a: *const TestView, b: *const TestView) bool {
        return a.id == b.id;
    }
};

test "buildSplitTree single pane" {
    var layout_arena: ArenaAllocator = .init(testing.allocator);
    defer layout_arena.deinit();
    const layout: Layout = try .parse(layout_arena.allocator(), "80x24,0,0,1");

    var view: TestView = .{ .id = 1 };
    const resolver: struct {
        view: *TestView,

        pub fn resolve(self: *const @This(), pane_id: usize) ?*TestView {
            return if (pane_id == self.view.id) self.view else null;
        }
    } = .{ .view = &view };

    var tree = try layout.buildSplitTree(TestView, testing.allocator, &resolver);
    defer tree.deinit();

    try testing.expectEqual(1, tree.nodes.len);
    try testing.expectEqual(&view, tree.nodes[0].leaf);
    // buildSplitTree refs the view; deinit will unref.
    try testing.expectEqual(2, view.ref_count);
}

test "buildSplitTree horizontal split" {
    var layout_arena: ArenaAllocator = .init(testing.allocator);
    defer layout_arena.deinit();
    const layout: Layout = try .parse(
        layout_arena.allocator(),
        "80x24,0,0{40x24,0,0,1,40x24,40,0,2}",
    );

    var views = [_]TestView{
        .{ .id = 1 },
        .{ .id = 2 },
    };
    const resolver: struct {
        views: []TestView,

        pub fn resolve(self: *const @This(), pane_id: usize) ?*TestView {
            for (self.views) |*v| {
                if (v.id == pane_id) return v;
            }
            return null;
        }
    } = .{ .views = &views };

    var tree = try layout.buildSplitTree(TestView, testing.allocator, &resolver);
    defer tree.deinit();

    // 1 split + 2 leaves = 3 nodes
    try testing.expectEqual(3, tree.nodes.len);

    // Root is a split
    const root = tree.nodes[0].split;
    try testing.expectEqual(.horizontal, root.layout);

    // Left leaf is pane 1, right leaf is pane 2
    try testing.expectEqual(&views[0], tree.nodes[root.left.idx()].leaf);
    try testing.expectEqual(&views[1], tree.nodes[root.right.idx()].leaf);

    // Ratio should be ~0.5 (40/80)
    try testing.expect(root.ratio > 0.4 and root.ratio < 0.6);
}

test "buildSplitTree missing pane returns empty" {
    var layout_arena: ArenaAllocator = .init(testing.allocator);
    defer layout_arena.deinit();
    const layout: Layout = try .parse(layout_arena.allocator(), "80x24,0,0,99");

    // Resolver that resolves nothing
    const resolver: struct {
        pub fn resolve(_: *const @This(), _: usize) ?*TestView {
            return null;
        }
    } = .{};

    var tree = try layout.buildSplitTree(TestView, testing.allocator, &resolver);
    defer tree.deinit();

    try testing.expectEqual(0, tree.nodes.len);
}

test "buildSplitTree nested vertical+horizontal" {
    var layout_arena: ArenaAllocator = .init(testing.allocator);
    defer layout_arena.deinit();
    // Vertical split containing a horizontal split and a leaf
    const layout: Layout = try .parse(
        layout_arena.allocator(),
        "80x24,0,0[80x12,0,0{40x12,0,0,1,40x12,40,0,2},80x12,0,12,3]",
    );

    var views = [_]TestView{
        .{ .id = 1 },
        .{ .id = 2 },
        .{ .id = 3 },
    };
    const resolver: struct {
        views: []TestView,

        pub fn resolve(self: *const @This(), pane_id: usize) ?*TestView {
            for (self.views) |*v| {
                if (v.id == pane_id) return v;
            }
            return null;
        }
    } = .{ .views = &views };

    var tree = try layout.buildSplitTree(TestView, testing.allocator, &resolver);
    defer tree.deinit();

    // Structure: vertical_split(horizontal_split(pane1, pane2), pane3)
    // = 2 splits + 3 leaves = 5 nodes
    try testing.expectEqual(5, tree.nodes.len);

    // Root is vertical
    const root = tree.nodes[0].split;
    try testing.expectEqual(.vertical, root.layout);

    // Left child of root is a horizontal split
    const left_split = tree.nodes[root.left.idx()].split;
    try testing.expectEqual(.horizontal, left_split.layout);

    // Right child of root is pane 3
    try testing.expectEqual(&views[2], tree.nodes[root.right.idx()].leaf);
}

test "countTreeNodes: single pane" {
    const layout: Layout = .{
        .width = 80,
        .height = 24,
        .x = 0,
        .y = 0,
        .content = .{ .pane = 1 },
    };
    try testing.expectEqual(@as(usize, 1), Layout.countTreeNodes(layout));
}

test "countTreeNodes: horizontal split two panes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // 80x24,0,0{40x24,0,0,1,40x24,40,0,2}
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    // Binary: split(leaf, leaf) = 1 split + 2 leaves = 3 nodes
    try testing.expectEqual(@as(usize, 3), Layout.countTreeNodes(layout));
}

test "countTreeNodes: vertical split two panes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0[80x12,0,0,1,80x12,0,12,2]");
    try testing.expectEqual(@as(usize, 3), Layout.countTreeNodes(layout));
}

test "countTreeNodes: three-way horizontal split" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // 80x24,0,0{27x24,0,0,1,26x24,28,0,2,26x24,55,0,3}
    const layout: Layout = try .parse(
        arena.allocator(),
        "80x24,0,0{27x24,0,0,1,26x24,28,0,2,26x24,55,0,3}",
    );
    // N-ary with 3 children → 2 split nodes + 3 leaves = 5
    try testing.expectEqual(@as(usize, 5), Layout.countTreeNodes(layout));
}

test "countTreeNodes: nested layout" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // 80x24,0,0{40x24,0,0,1,40x24,40,0[40x12,40,0,2,40x12,40,12,3]}
    const layout: Layout = try .parse(
        arena.allocator(),
        "80x24,0,0{40x24,0,0,1,40x24,40,0[40x12,40,0,2,40x12,40,12,3]}",
    );
    // Outer horizontal: split(leaf=1, vertical_split(leaf=2, leaf=3))
    // = 1 outer split + 1 leaf + 1 inner split + 2 leaves = 5
    try testing.expectEqual(@as(usize, 5), Layout.countTreeNodes(layout));
}

test "countChildrenNodes: empty children" {
    const empty: []const Layout = &.{};
    try testing.expectEqual(@as(usize, 0), Layout.countChildrenNodes(empty));
}

test "countChildrenNodes: single child pane" {
    const children: []const Layout = &.{
        .{ .width = 80, .height = 24, .x = 0, .y = 0, .content = .{ .pane = 1 } },
    };
    try testing.expectEqual(@as(usize, 1), Layout.countChildrenNodes(children));
}

test "computeSplitRatio: equal horizontal split" {
    const children: []const Layout = &.{
        .{ .width = 40, .height = 24, .x = 0, .y = 0, .content = .{ .pane = 1 } },
        .{ .width = 40, .height = 24, .x = 40, .y = 0, .content = .{ .pane = 2 } },
    };
    const ratio = Layout.computeSplitRatio(true, children);
    try testing.expectEqual(@as(f16, 0.5), ratio);
}

test "computeSplitRatio: unequal horizontal split" {
    const children: []const Layout = &.{
        .{ .width = 60, .height = 24, .x = 0, .y = 0, .content = .{ .pane = 1 } },
        .{ .width = 20, .height = 24, .x = 60, .y = 0, .content = .{ .pane = 2 } },
    };
    const ratio = Layout.computeSplitRatio(true, children);
    try testing.expectEqual(@as(f16, 0.75), ratio);
}

test "computeSplitRatio: equal vertical split" {
    const children: []const Layout = &.{
        .{ .width = 80, .height = 12, .x = 0, .y = 0, .content = .{ .pane = 1 } },
        .{ .width = 80, .height = 12, .x = 0, .y = 12, .content = .{ .pane = 2 } },
    };
    const ratio = Layout.computeSplitRatio(false, children);
    try testing.expectEqual(@as(f16, 0.5), ratio);
}

test "computeSplitRatio: three-way split uses first child ratio" {
    // With three children [27, 26, 26], first ratio = 27/79
    const children: []const Layout = &.{
        .{ .width = 27, .height = 24, .x = 0, .y = 0, .content = .{ .pane = 1 } },
        .{ .width = 26, .height = 24, .x = 28, .y = 0, .content = .{ .pane = 2 } },
        .{ .width = 26, .height = 24, .x = 55, .y = 0, .content = .{ .pane = 3 } },
    };
    const ratio = Layout.computeSplitRatio(true, children);
    const expected: f16 = @floatCast(@as(f64, 27.0) / @as(f64, 79.0));
    try testing.expectEqual(expected, ratio);
}

test "computeSplitRatio: single child returns 0.5" {
    const children: []const Layout = &.{
        .{ .width = 80, .height = 24, .x = 0, .y = 0, .content = .{ .pane = 1 } },
    };
    const ratio = Layout.computeSplitRatio(true, children);
    try testing.expectEqual(@as(f16, 0.5), ratio);
}

test "computeSplitRatio: empty children returns 0.5" {
    const empty: []const Layout = &.{};
    const ratio = Layout.computeSplitRatio(true, empty);
    try testing.expectEqual(@as(f16, 0.5), ratio);
}

test "computeSplitRatio: zero dimension returns 0.5" {
    const children: []const Layout = &.{
        .{ .width = 0, .height = 24, .x = 0, .y = 0, .content = .{ .pane = 1 } },
        .{ .width = 0, .height = 24, .x = 0, .y = 0, .content = .{ .pane = 2 } },
    };
    const ratio = Layout.computeSplitRatio(true, children);
    try testing.expectEqual(@as(f16, 0.5), ratio);
}
