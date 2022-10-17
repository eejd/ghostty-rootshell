const std = @import("std");
const c = @import("c.zig");
const imgui = @import("main.zig");
const Allocator = std.mem.Allocator;

pub const newFrame = c.igNewFrame;
pub const endFrame = c.igEndFrame;
pub const render = c.igRender;
pub const end = c.igEnd;
pub const beginTooltip = c.igBeginTooltip;
pub const endTooltip = c.igEndTooltip;
pub const spacing = c.igSpacing;
pub const text = c.igText;
pub const textDisabled = c.igTextDisabled;
pub const textWrapped = c.igTextWrapped;
pub const button = c.igButton;
pub const sameLine = c.igSameLine;
pub const getFontSize = c.igGetFontSize;
pub const pushTextWrapPos = c.igPushTextWrapPos;
pub const popTextWrapPos = c.igPopTextWrapPos;
pub const treePop = c.igTreePop;

pub fn showDemoWindow(open: ?*bool) void {
    c.igShowDemoWindow(@ptrCast([*c]bool, if (open) |v| v else null));
}

pub fn begin(name: [:0]const u8, open: ?*bool, flags: WindowFlags) bool {
    return c.igBegin(
        name.ptr,
        @ptrCast([*c]bool, if (open) |v| v else null),
        @bitCast(c_int, flags),
    );
}

pub fn collapsingHeader(
    label: [:0]const u8,
    visible: ?*bool,
    flags: TreeNodeFlags,
) bool {
    return c.igCollapsingHeader_BoolPtr(
        label.ptr,
        @ptrCast([*c]bool, if (visible) |v| v else null),
        @bitCast(c_int, flags),
    );
}

pub fn isItemHovered(flags: HoveredFlags) bool {
    return c.igIsItemHovered(
        @bitCast(c_int, flags),
    );
}

pub fn treeNode(
    label: [:0]const u8,
    flags: TreeNodeFlags,
) bool {
    return c.igTreeNodeEx_Str(
        label.ptr,
        @bitCast(c_int, flags),
    );
}

pub const WindowFlags = packed struct {
    no_title_bar: bool = false,
    no_resize: bool = false,
    no_move: bool = false,
    no_scrollbar: bool = false,
    no_scrollbar_with_mouse: bool = false,
    no_collapse: bool = false,
    always_auto_resize: bool = false,
    no_background: bool = false,
    no_saved_settings: bool = false,
    no_mouse_inputs: bool = false,
    menu_bar: bool = false,
    horizontal_scroll_bar: bool = false,
    no_focus_on_appearing: bool = false,
    no_bring_to_front_on_focus: bool = false,
    always_vertical_scrollbar: bool = false,
    always_horizontal_scrollbar: bool = false,
    always_use_window_padding: bool = false,
    no_nav_inputs: bool = false,
    no_nav_focus: bool = false,
    unsaved_document: bool = false,
    no_docking: bool = false,
    _unusued_1: u1 = 0,
    nav_flattened: bool = false,
    child_window: bool = false,
    tooltip: bool = false,
    popup: bool = false,
    modal: bool = false,
    child_menu: bool = false,
    dock_node_host: bool = false,
    _padding: u3 = 0,

    test {
        try std.testing.expectEqual(@bitSizeOf(c_int), @bitSizeOf(WindowFlags));
    }
};

pub const TreeNodeFlags = packed struct {
    selected: bool = false,
    framed: bool = false,
    allow_item_overlap: bool = false,
    no_tree_push_on_open: bool = false,
    no_auto_open_on_log: bool = false,
    default_open: bool = false,
    open_on_double_click: bool = false,
    open_on_arrow: bool = false,
    leaf: bool = false,
    bullet: bool = false,
    frame_padding: bool = false,
    span_avail_width: bool = false,
    span_full_width: bool = false,
    nav_left_jumps_back_here: bool = false,
    _padding: u18 = 0,

    test {
        try std.testing.expectEqual(@bitSizeOf(c_int), @bitSizeOf(TreeNodeFlags));
    }
};

pub const HoveredFlags = packed struct {
    child_windows: bool = false,
    root_window: bool = false,
    any_window: bool = false,
    no_popup_hierarchy: bool = false,
    dock_hierarchy: bool = false,
    allow_when_blocked_by_popup: bool = false,
    allow_when_blocked_by_active_item: bool = false,
    allow_when_overlapped: bool = false,
    allow_when_disabled: bool = false,
    no_nav_override: bool = false,
    _padding: u22 = 0,

    test {
        try std.testing.expectEqual(@bitSizeOf(c_int), @bitSizeOf(HoveredFlags));
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
