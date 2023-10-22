//! The Inspector is a development tool to debug the terminal. This is
//! useful for terminal application developers as well as people potentially
//! debugging issues in Ghostty itself.
const Inspector = @This();

const std = @import("std");
const builtin = @import("builtin");
const cimgui = @import("cimgui");
const Surface = @import("Surface.zig");
const terminal = @import("terminal/main.zig");

/// The window names. These are used with docking so we need to have access.
const window_modes = "Modes";
const window_screen = "Screen";
const window_size = "Surface Info";
const window_imgui_demo = "Dear ImGui Demo";

/// The surface that we're inspecting.
surface: *Surface,

/// This is used to track whether we're rendering for the first time. This
/// is used to set up the initial window positions.
first_render: bool = true,

show_modes_window: bool = true,
show_screen_window: bool = true,
show_size_window: bool = true,

/// Setup the ImGui state. This requires an ImGui context to be set.
pub fn setup() void {
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();

    // Enable docking, which we use heavily for the UI.
    io.ConfigFlags |= cimgui.c.ImGuiConfigFlags_DockingEnable;

    // Our colorspace is sRGB.
    io.ConfigFlags |= cimgui.c.ImGuiConfigFlags_IsSRGB;

    // Disable the ini file to save layout
    io.IniFilename = null;
    io.LogFilename = null;

    // Use our own embedded font
    {
        // TODO: This will have to be recalculated for different screen DPIs.
        // This is currently hardcoded to a 2x content scale.
        const font_size = 16 * 2;

        const font_config: *cimgui.c.ImFontConfig = cimgui.c.ImFontConfig_ImFontConfig();
        defer cimgui.c.ImFontConfig_destroy(font_config);
        font_config.FontDataOwnedByAtlas = false;
        _ = cimgui.c.ImFontAtlas_AddFontFromMemoryTTF(
            io.Fonts,
            @constCast(@ptrCast(Surface.face_ttf)),
            Surface.face_ttf.len,
            font_size,
            font_config,
            null,
        );
    }
}

pub fn init(surface: *Surface) Inspector {
    return .{ .surface = surface };
}

pub fn deinit(self: *Inspector) void {
    _ = self;
}

/// Render the frame.
pub fn render(self: *Inspector) void {
    const dock_id = cimgui.c.igDockSpaceOverViewport(
        cimgui.c.igGetMainViewport(),
        cimgui.c.ImGuiDockNodeFlags_None,
        null,
    );

    // Render all of our data. We hold the mutex for this duration. This is
    // expensive but this is an initial implementation until it doesn't work
    // anymore.
    {
        self.surface.renderer_state.mutex.lock();
        defer self.surface.renderer_state.mutex.unlock();
        self.renderScreenWindow();
        self.renderModesWindow();
        self.renderSizeWindow();
    }

    // In debug we show the ImGui demo window so we can easily view available
    // widgets and such.
    if (builtin.mode == .Debug) {
        var show: bool = true;
        cimgui.c.igShowDemoWindow(&show);
    }

    // On first render we set up the layout. We can actually do this at
    // the end of the frame, allowing the individual rendering to also
    // observe the first render flag.
    if (self.first_render) {
        self.first_render = false;
        self.setupLayout(dock_id);
    }
}

fn setupLayout(self: *Inspector, dock_id_main: cimgui.c.ImGuiID) void {
    _ = self;

    // Our initial focus should always be the modes window
    cimgui.c.igSetWindowFocus_Str(window_screen);

    // Setup our initial layout.
    const dock_id: struct {
        left: cimgui.c.ImGuiID,
        right: cimgui.c.ImGuiID,
    } = dock_id: {
        var dock_id_left: cimgui.c.ImGuiID = undefined;
        var dock_id_right: cimgui.c.ImGuiID = undefined;
        _ = cimgui.c.igDockBuilderSplitNode(
            dock_id_main,
            cimgui.c.ImGuiDir_Left,
            0.7,
            &dock_id_left,
            &dock_id_right,
        );

        break :dock_id .{
            .left = dock_id_left,
            .right = dock_id_right,
        };
    };

    cimgui.c.igDockBuilderDockWindow(window_modes, dock_id.left);
    cimgui.c.igDockBuilderDockWindow(window_screen, dock_id.left);
    cimgui.c.igDockBuilderDockWindow(window_imgui_demo, dock_id.left);
    cimgui.c.igDockBuilderDockWindow(window_size, dock_id.right);
    cimgui.c.igDockBuilderFinish(dock_id_main);
}

fn renderScreenWindow(self: *Inspector) void {
    if (!self.show_screen_window) return;

    // Start our window. If we're collapsed we do nothing.
    defer cimgui.c.igEnd();
    if (!cimgui.c.igBegin(
        window_screen,
        &self.show_screen_window,
        cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
    )) return;

    const t = self.surface.renderer_state.terminal;
    const screen = &t.screen;

    {
        _ = cimgui.c.igBeginTable(
            "table_screen",
            2,
            cimgui.c.ImGuiTableFlags_None,
            .{ .x = 0, .y = 0 },
            0,
        );
        defer cimgui.c.igEndTable();

        {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Active Screen");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText("%s", @tagName(t.active_screen).ptr);
            }
        }
    }

    if (cimgui.c.igCollapsingHeader_TreeNodeFlags(
        "Cursor",
        cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
    )) {
        {
            _ = cimgui.c.igBeginTable(
                "table_cursor",
                2,
                cimgui.c.ImGuiTableFlags_None,
                .{ .x = 0, .y = 0 },
                0,
            );
            defer cimgui.c.igEndTable();

            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Position (x, y)");
                }
                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("(%d, %d)", screen.cursor.x, screen.cursor.y);
                }
            }

            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Pending Wrap");
                }
                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("%s", if (screen.cursor.pending_wrap) "true".ptr else "false".ptr);
                }
            }

            // If we have a color then we show the color
            color: {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Foreground Color");
                _ = cimgui.c.igTableSetColumnIndex(1);
                if (!screen.cursor.pen.attrs.has_fg) {
                    cimgui.c.igText("default");
                    break :color;
                }

                var color: [3]f32 = .{
                    @as(f32, @floatFromInt(screen.cursor.pen.fg.r)) / 255,
                    @as(f32, @floatFromInt(screen.cursor.pen.fg.g)) / 255,
                    @as(f32, @floatFromInt(screen.cursor.pen.fg.b)) / 255,
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
                if (!screen.cursor.pen.attrs.has_bg) {
                    cimgui.c.igText("default");
                    break :color;
                }

                var color: [3]f32 = .{
                    @as(f32, @floatFromInt(screen.cursor.pen.bg.r)) / 255,
                    @as(f32, @floatFromInt(screen.cursor.pen.bg.g)) / 255,
                    @as(f32, @floatFromInt(screen.cursor.pen.bg.b)) / 255,
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
                if (!@field(screen.cursor.pen.attrs, style)) break :style;

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
        } // table

        cimgui.c.igTextDisabled("(Any styles not shown are not currently set)");
    } // cursor

    if (cimgui.c.igCollapsingHeader_TreeNodeFlags(
        "Keyboard",
        cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
    )) {
        {
            _ = cimgui.c.igBeginTable(
                "table_keyboard",
                2,
                cimgui.c.ImGuiTableFlags_None,
                .{ .x = 0, .y = 0 },
                0,
            );
            defer cimgui.c.igEndTable();

            const kitty_flags = screen.kitty_keyboard.current();

            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Mode");
                }
                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    const mode = if (kitty_flags.int() != 0) "kitty" else "legacy";
                    cimgui.c.igText("%s", mode.ptr);
                }
            }

            if (kitty_flags.int() != 0) {
                const Flags = @TypeOf(kitty_flags);
                inline for (@typeInfo(Flags).Struct.fields) |field| {
                    {
                        const value = @field(kitty_flags, field.name);

                        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                        {
                            _ = cimgui.c.igTableSetColumnIndex(0);
                            const name = std.fmt.comptimePrint("{s}", .{field.name});
                            cimgui.c.igText("%s", name.ptr);
                        }
                        {
                            _ = cimgui.c.igTableSetColumnIndex(1);
                            cimgui.c.igText(
                                "%s",
                                if (value) "true".ptr else "false".ptr,
                            );
                        }
                    }
                }
            } else {
                {
                    cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                    {
                        _ = cimgui.c.igTableSetColumnIndex(0);
                        cimgui.c.igText("Xterm modify keys");
                    }
                    {
                        _ = cimgui.c.igTableSetColumnIndex(1);
                        cimgui.c.igText(
                            "%s",
                            if (t.flags.modify_other_keys_2) "true".ptr else "false".ptr,
                        );
                    }
                }
            } // keyboard mode info
        } // table
    } // keyboard
}

/// The modes window shows the currently active terminal modes and allows
/// users to toggle them on and off.
fn renderModesWindow(self: *Inspector) void {
    if (!self.show_modes_window) return;

    // Start our window. If we're collapsed we do nothing.
    defer cimgui.c.igEnd();
    if (!cimgui.c.igBegin(
        window_modes,
        &self.show_modes_window,
        cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
    )) return;

    _ = cimgui.c.igBeginTable(
        "table_modes",
        3,
        cimgui.c.ImGuiTableFlags_SizingFixedFit |
            cimgui.c.ImGuiTableFlags_RowBg,
        .{ .x = 0, .y = 0 },
        0,
    );
    defer cimgui.c.igEndTable();

    {
        _ = cimgui.c.igTableSetupColumn("", cimgui.c.ImGuiTableColumnFlags_NoResize, 0, 0);
        _ = cimgui.c.igTableSetupColumn("Number", cimgui.c.ImGuiTableColumnFlags_PreferSortAscending, 0, 0);
        _ = cimgui.c.igTableSetupColumn("Name", cimgui.c.ImGuiTableColumnFlags_WidthStretch, 0, 0);
        cimgui.c.igTableHeadersRow();
    }

    const t = self.surface.renderer_state.terminal;
    inline for (@typeInfo(terminal.Mode).Enum.fields) |field| {
        const tag: terminal.modes.ModeTag = @bitCast(@as(terminal.modes.ModeTag.Backing, field.value));

        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        {
            _ = cimgui.c.igTableSetColumnIndex(0);
            var value: bool = t.modes.get(@field(terminal.Mode, field.name));
            _ = cimgui.c.igCheckbox("", &value);
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText(
                "%s%d",
                if (tag.ansi) "?" else "",
                @as(u32, @intCast(tag.value)),
            );
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(2);
            const name = std.fmt.comptimePrint("{s}", .{field.name});
            cimgui.c.igText("%s", name.ptr);
        }
    }
}

fn renderSizeWindow(self: *Inspector) void {
    if (!self.show_size_window) return;

    // Start our window. If we're collapsed we do nothing.
    defer cimgui.c.igEnd();
    if (!cimgui.c.igBegin(
        window_size,
        &self.show_size_window,
        cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
    )) return;

    cimgui.c.igSeparatorText("Dimensions");

    {
        _ = cimgui.c.igBeginTable(
            "table_size",
            2,
            cimgui.c.ImGuiTableFlags_None,
            .{ .x = 0, .y = 0 },
            0,
        );
        defer cimgui.c.igEndTable();

        // Screen Size
        {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Screen Size");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText(
                    "%d x %d",
                    self.surface.screen_size.width,
                    self.surface.screen_size.height,
                );
            }
        }

        // Grid Size
        {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Grid Size");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText(
                    "%d x %d",
                    self.surface.grid_size.columns,
                    self.surface.grid_size.rows,
                );
            }
        }

        // Cell Size
        {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Cell Size");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText(
                    "%d x %d",
                    self.surface.cell_size.width,
                    self.surface.cell_size.height,
                );
            }
        }

        // Padding
        {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Window Padding");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText(
                    "T=%d B=%d L=%d R=%d",
                    self.surface.padding.top,
                    self.surface.padding.bottom,
                    self.surface.padding.left,
                    self.surface.padding.right,
                );
            }
        }
    }

    cimgui.c.igSeparatorText("Font");

    {
        _ = cimgui.c.igBeginTable(
            "table_font",
            2,
            cimgui.c.ImGuiTableFlags_None,
            .{ .x = 0, .y = 0 },
            0,
        );
        defer cimgui.c.igEndTable();

        {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Size (Points)");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText(
                    "%d pt",
                    self.surface.font_size.points,
                );
            }
        }

        {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Size (Pixels)");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText(
                    "%d px",
                    self.surface.font_size.pixels(),
                );
            }
        }
    }
}
