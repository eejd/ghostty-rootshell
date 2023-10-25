const std = @import("std");
const cimgui = @import("cimgui");
const terminal = @import("../terminal/main.zig");

/// Render cursor information with a table already open.
pub fn renderInTable(cursor: *const terminal.Screen.Cursor) void {
    {
        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        {
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Position (x, y)");
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText("(%d, %d)", cursor.x, cursor.y);
        }
    }

    if (cursor.pending_wrap) {
        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        {
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Pending Wrap");
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText("%s", if (cursor.pending_wrap) "true".ptr else "false".ptr);
        }
    }

    // If we have a color then we show the color
    color: {
        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        _ = cimgui.c.igTableSetColumnIndex(0);
        cimgui.c.igText("Foreground Color");
        _ = cimgui.c.igTableSetColumnIndex(1);
        if (!cursor.pen.attrs.has_fg) {
            cimgui.c.igText("default");
            break :color;
        }

        var color: [3]f32 = .{
            @as(f32, @floatFromInt(cursor.pen.fg.r)) / 255,
            @as(f32, @floatFromInt(cursor.pen.fg.g)) / 255,
            @as(f32, @floatFromInt(cursor.pen.fg.b)) / 255,
        };
        _ = cimgui.c.igColorEdit3(
            "color_fg",
            &color,
            cimgui.c.ImGuiColorEditFlags_NoPicker |
                cimgui.c.ImGuiColorEditFlags_NoLabel,
        );
    }
    color: {
        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        _ = cimgui.c.igTableSetColumnIndex(0);
        cimgui.c.igText("Background Color");
        _ = cimgui.c.igTableSetColumnIndex(1);
        if (!cursor.pen.attrs.has_bg) {
            cimgui.c.igText("default");
            break :color;
        }

        var color: [3]f32 = .{
            @as(f32, @floatFromInt(cursor.pen.bg.r)) / 255,
            @as(f32, @floatFromInt(cursor.pen.bg.g)) / 255,
            @as(f32, @floatFromInt(cursor.pen.bg.b)) / 255,
        };
        _ = cimgui.c.igColorEdit3(
            "color_bg",
            &color,
            cimgui.c.ImGuiColorEditFlags_NoPicker |
                cimgui.c.ImGuiColorEditFlags_NoLabel,
        );
    }

    // Boolean styles
    const styles = .{
        "bold",    "italic",    "faint",     "blink",
        "inverse", "invisible", "protected", "strikethrough",
    };
    inline for (styles) |style| style: {
        if (!@field(cursor.pen.attrs, style)) break :style;

        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        {
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText(style.ptr);
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText("true");
        }
    }
}
