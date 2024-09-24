const std = @import("std");
const inputpkg = @import("../input.zig");
const args = @import("args.zig");
const Action = @import("action.zig").Action;
const Config = @import("../config/Config.zig");
const themepkg = @import("../config/theme.zig");
const tui = @import("tui.zig");
const internal_os = @import("../os/main.zig");
const global_state = &@import("../global.zig").state;

const vaxis = @import("vaxis");

pub const Options = struct {
    /// If true, print the full path to the theme.
    path: bool = false,

    /// If true, force a plain list of themes.
    plain: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

const ThemeListElement = struct {
    location: themepkg.Location,
    path: []const u8,
    theme: []const u8,

    fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
        // TODO: use Unicode-aware comparison
        return std.ascii.orderIgnoreCase(lhs.theme, rhs.theme) == .lt;
    }

    pub fn toUri(self: *const ThemeListElement, alloc: std.mem.Allocator) ![]const u8 {
        const uri = std.Uri{
            .scheme = "file",
            .host = .{ .raw = "" },
            .path = .{ .raw = self.path },
        };
        var buf = std.ArrayList(u8).init(alloc);
        errdefer buf.deinit();
        try uri.writeToStream(.{ .scheme = true, .authority = true, .path = true }, buf.writer());
        return buf.toOwnedSlice();
    }
};

/// The `list-themes` command is used to preview or list all the available
/// themes for Ghostty.
///
/// Two different directories will be searched for themes.
///
/// The first directory is the `themes` subdirectory of your Ghostty
/// configuration directory. This is `$XDG_CONFIG_DIR/ghostty/themes` or
/// `~/.config/ghostty/themes`.
///
/// The second directory is the `themes` subdirectory of the Ghostty resources
/// directory. Ghostty ships with a multitude of themes that will be installed
/// into this directory. On macOS, this directory is the `Ghostty.app/Contents/
/// Resources/ghostty/themes`. On Linux, this directory is the `share/ghostty/
/// themes` (wherever you installed the Ghostty "share" directory). If you're
/// running Ghostty from the source, this is the `zig-out/share/ghostty/themes`
/// directory.
///
/// You can also set the `GHOSTTY_RESOURCES_DIR` environment variable to point
/// to the resources directory.
///
/// Flags:
///
///   * `--path`: Show the full path to the theme.
///   * `--plain`: Show a short preview of the theme colors.
pub fn run(gpa_alloc: std.mem.Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try std.process.argsWithAllocator(gpa_alloc);
        defer iter.deinit();
        try args.parse(Options, gpa_alloc, &opts, &iter);
    }

    var arena = std.heap.ArenaAllocator.init(gpa_alloc);
    const alloc = arena.allocator();

    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    if (global_state.resources_dir == null)
        try stderr.print("Could not find the Ghostty resources directory. Please ensure " ++
            "that Ghostty is installed correctly.\n", .{});

    var count: usize = 0;

    var themes = std.ArrayList(ThemeListElement).init(alloc);

    var it = themepkg.LocationIterator{ .arena_alloc = arena.allocator() };

    while (try it.next()) |loc| {
        var dir = std.fs.cwd().openDir(loc.dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                std.debug.print("error trying to open {s}: {}\n", .{ loc.dir, err });
                continue;
            },
        };
        defer dir.close();

        var walker = dir.iterate();

        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .file, .sym_link => {
                    count += 1;
                    try themes.append(.{
                        .location = loc.location,
                        .path = try std.fs.path.join(alloc, &.{ loc.dir, entry.name }),
                        .theme = try alloc.dupe(u8, entry.name),
                    });
                },
                else => {},
            }
        }
    }

    if (count == 0) {
        try stderr.print("No themes found, check to make sure that the themes were installed correctly.", .{});
        return 1;
    }

    std.mem.sortUnstable(ThemeListElement, themes.items, {}, ThemeListElement.lessThan);

    if (tui.can_pretty_print and !opts.plain and std.posix.isatty(std.io.getStdOut().handle)) {
        try preview(gpa_alloc, themes.items);
        return 0;
    }

    for (themes.items) |theme| {
        if (opts.path)
            try stdout.print("{s} ({s}) {s}\n", .{ theme.theme, @tagName(theme.location), theme.path })
        else
            try stdout.print("{s} ({s})\n", .{ theme.theme, @tagName(theme.location) });
    }

    return 0;
}

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    color_scheme: vaxis.Color.Scheme,
    winsize: vaxis.Winsize,
};

const Preview = struct {
    allocator: std.mem.Allocator,
    should_quit: bool,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    mouse: ?vaxis.Mouse,
    themes: []ThemeListElement,
    current: usize,
    hex: bool,
    help_visible: bool,
    color_scheme: vaxis.Color.Scheme,

    pub fn init(allocator: std.mem.Allocator, themes: []ThemeListElement) !Preview {
        return .{
            .allocator = allocator,
            .should_quit = false,
            .tty = try vaxis.Tty.init(),
            .vx = try vaxis.init(allocator, .{}),
            .mouse = null,
            .themes = themes,
            .current = 0,
            .hex = false,
            .help_visible = false,
            .color_scheme = .light,
        };
    }

    pub fn deinit(self: *Preview) void {
        self.vx.deinit(self.allocator, self.tty.anyWriter());
        self.tty.deinit();
    }

    pub fn run(self: *Preview) !void {
        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };
        try loop.init();
        try loop.start();

        try self.vx.enterAltScreen(self.tty.anyWriter());
        try self.vx.setTitle(self.tty.anyWriter(), "👻 Ghostty Theme Preview 👻");
        try self.vx.queryTerminal(self.tty.anyWriter(), 1 * std.time.ns_per_s);
        try self.vx.setMouseMode(self.tty.anyWriter(), true);
        if (self.vx.caps.color_scheme_updates)
            try self.vx.subscribeToColorSchemeUpdates(self.tty.anyWriter());

        while (!self.should_quit) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            loop.pollEvent();
            while (loop.tryEvent()) |event| {
                try self.update(event, alloc);
            }
            try self.draw(alloc);

            var buffered = self.tty.bufferedWriter();
            try self.vx.render(buffered.writer().any());
            try buffered.flush();
        }
    }

    fn up(self: *Preview, count: usize) void {
        self.current = std.math.sub(usize, self.current, count) catch self.themes.len + self.current - count;
    }

    fn down(self: *Preview, count: usize) void {
        self.current = (self.current + count) % self.themes.len;
    }

    pub fn update(self: *Preview, event: Event, alloc: std.mem.Allocator) !void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }))
                    self.should_quit = true;
                if (key.matches('q', .{}))
                    self.should_quit = true;
                if (key.matches(vaxis.Key.escape, .{}))
                    self.should_quit = true;
                if (key.matches('?', .{}))
                    self.help_visible = !self.help_visible;
                if (key.matches('h', .{ .ctrl = true }))
                    self.help_visible = !self.help_visible;
                if (key.matches(vaxis.Key.f1, .{}))
                    self.help_visible = !self.help_visible;
                if (key.matches('0', .{}))
                    self.current = 0;
                if (key.matches(vaxis.Key.home, .{}))
                    self.current = 0;
                if (key.matches(vaxis.Key.kp_home, .{}))
                    self.current = 0;
                if (key.matches(vaxis.Key.end, .{}))
                    self.current = self.themes.len - 1;
                if (key.matches(vaxis.Key.kp_end, .{}))
                    self.current = self.themes.len - 1;
                if (key.matches('j', .{}))
                    self.down(1);
                if (key.matches('+', .{}))
                    self.down(1);
                if (key.matches(vaxis.Key.down, .{}))
                    self.down(1);
                if (key.matches(vaxis.Key.kp_down, .{}))
                    self.down(1);
                if (key.matches(vaxis.Key.kp_add, .{}))
                    self.down(1);
                if (key.matches(vaxis.Key.page_down, .{}))
                    self.down(20);
                if (key.matches(vaxis.Key.kp_page_down, .{}))
                    self.down(20);
                if (key.matches('k', .{}))
                    self.up(1);
                if (key.matches('-', .{}))
                    self.up(1);
                if (key.matches(vaxis.Key.up, .{}))
                    self.up(1);
                if (key.matches(vaxis.Key.kp_up, .{}))
                    self.up(1);
                if (key.matches(vaxis.Key.kp_subtract, .{}))
                    self.up(1);
                if (key.matches(vaxis.Key.page_up, .{}))
                    self.up(20);
                if (key.matches(vaxis.Key.kp_page_up, .{}))
                    self.up(20);
                if (key.matches('h', .{}))
                    self.hex = true;
                if (key.matches('x', .{}))
                    self.hex = true;
                if (key.matches('d', .{}))
                    self.hex = false;
                if (key.matches('c', .{}))
                    try self.vx.copyToSystemClipboard(
                        self.tty.anyWriter(),
                        self.themes[self.current].theme,
                        alloc,
                    );
                if (key.matches('c', .{ .shift = true }))
                    try self.vx.copyToSystemClipboard(
                        self.tty.anyWriter(),
                        self.themes[self.current].path,
                        alloc,
                    );
            },
            .color_scheme => |color_scheme| self.color_scheme = color_scheme,
            .mouse => |mouse| self.mouse = mouse,
            .winsize => |ws| try self.vx.resize(self.allocator, self.tty.anyWriter(), ws),
        }
    }

    pub fn draw(self: *Preview, alloc: std.mem.Allocator) !void {
        const win = self.vx.window();
        win.clear();

        self.vx.setMouseShape(.default);

        const ui_fg: vaxis.Color = switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0x00, 0x00, 0x00 } },
            .dark => .{ .rgb = [_]u8{ 0xff, 0xff, 0xff } },
        };
        const ui_bg: vaxis.Color = switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0xff, 0xff, 0xff } },
            .dark => .{ .rgb = [_]u8{ 0x00, 0x00, 0x00 } },
        };
        const ui_standard: vaxis.Style = .{
            .fg = ui_fg,
            .bg = ui_bg,
        };

        const ui_hover_bg: vaxis.Color = switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0xbb, 0xbb, 0xbb } },
            .dark => .{ .rgb = [_]u8{ 0x22, 0x22, 0x22 } },
        };

        const ui_selected_fg: vaxis.Color = switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0x00, 0xaa, 0x00 } },
            .dark => .{ .rgb = [_]u8{ 0x00, 0xaa, 0x00 } },
        };
        const ui_selected_bg: vaxis.Color = switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0xaa, 0xaa, 0xaa } },
            .dark => .{ .rgb = [_]u8{ 0x33, 0x33, 0x33 } },
        };
        const ui_selected: vaxis.Style = .{
            .fg = ui_selected_fg,
            .bg = ui_selected_bg,
        };

        const theme_list = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = .{ .limit = 32 },
            .height = .{ .limit = win.height },
        });

        const split = theme_list.height / 2;

        var highlight: ?usize = null;

        if (self.mouse) |mouse| {
            self.mouse = null;
            if (mouse.button == .wheel_up) {
                self.up(1);
            }
            if (mouse.button == .wheel_down) {
                self.down(1);
            }
            if (theme_list.hasMouse(mouse)) |_| {
                if (mouse.button == .left and mouse.type == .release) {
                    if (mouse.row < split) self.up(split - mouse.row);
                    if (mouse.row > split) self.down(mouse.row - split);
                }
                highlight = mouse.row;
            }
        }

        theme_list.fill(.{ .style = ui_standard });

        for (0..split) |i| {
            const j = std.math.sub(usize, self.current, i + 1) catch self.themes.len + self.current - i - 1;
            const theme = self.themes[j];
            const row = split - i - 1;

            _ = try theme_list.printSegment(
                .{
                    .text = theme.theme,
                    .style = .{
                        .fg = ui_fg,
                        .bg = bg: {
                            if (highlight) |h| if (h == row) break :bg ui_hover_bg;
                            break :bg ui_bg;
                        },
                    },
                    .link = .{
                        .uri = try theme.toUri(alloc),
                    },
                },
                .{
                    .row_offset = row,
                    .col_offset = 2,
                },
            );
        }
        {
            const theme = self.themes[self.current];
            _ = try theme_list.printSegment(
                .{
                    .text = "❯ ",
                    .style = ui_selected,
                },
                .{
                    .row_offset = split,
                    .col_offset = 0,
                },
            );
            _ = try theme_list.printSegment(
                .{
                    .text = theme.theme,
                    .style = ui_selected,
                    .link = .{
                        .uri = try theme.toUri(alloc),
                    },
                },
                .{
                    .row_offset = split,
                    .col_offset = 2,
                },
            );
            if (theme.theme.len < theme_list.width - 4) {
                for (2 + theme.theme.len..theme_list.width - 2) |i|
                    _ = try theme_list.printSegment(
                        .{
                            .text = " ",
                            .style = ui_selected,
                        },
                        .{
                            .row_offset = split,
                            .col_offset = i,
                        },
                    );
            }
            _ = try theme_list.printSegment(
                .{
                    .text = " ❮",
                    .style = ui_selected,
                },
                .{
                    .row_offset = split,
                    .col_offset = theme_list.width - 2,
                },
            );
        }
        for (split + 1..theme_list.height) |i| {
            const j = (self.current + i - split) % self.themes.len;
            const row = i;
            const theme = self.themes[j];
            _ = try theme_list.printSegment(.{
                .text = theme.theme,
                .style = .{
                    .fg = ui_fg,
                    .bg = bg: {
                        if (highlight) |h| if (h == row) break :bg ui_hover_bg;
                        break :bg ui_bg;
                    },
                },
                .link = .{
                    .uri = try theme.toUri(alloc),
                },
            }, .{
                .row_offset = i,
                .col_offset = 2,
            });
        }

        try self.drawPreview(alloc, win, theme_list.x_off + theme_list.width, ui_fg, ui_bg);

        if (self.help_visible) {
            const width = 60;
            const height = 20;
            const child = win.child(
                .{
                    .x_off = win.width / 2 -| width / 2,
                    .y_off = win.height / 2 -| height / 2,
                    .width = .{
                        .limit = width,
                    },
                    .height = .{
                        .limit = height,
                    },
                    .border = .{
                        .where = .all,
                        .style = ui_standard,
                    },
                },
            );

            child.fill(.{ .style = ui_standard });

            const key_help = [_]struct { keys: []const u8, help: []const u8 }{
                .{ .keys = "^C, q, ESC", .help = "Quit." },
                .{ .keys = "F1, ?, ^H", .help = "Toggle help window." },
                .{ .keys = "k, ↑", .help = "Move up 1 theme." },
                .{ .keys = "ScrollUp", .help = "Move up 1 theme." },
                .{ .keys = "PgUp", .help = "Move up 20 themes." },
                .{ .keys = "j, ↓", .help = "Move down 1 theme." },
                .{ .keys = "ScrollDown", .help = "Move down 1 theme." },
                .{ .keys = "PgDown", .help = "Move down 20 themes." },
                .{ .keys = "h, x", .help = "Show palette numbers in hexadecimal." },
                .{ .keys = "d", .help = "Show palette numbers in decimal." },
                .{ .keys = "c", .help = "Copy theme name to the clipboard." },
                .{ .keys = "C", .help = "Copy theme path to the clipboard." },
                .{ .keys = "0, Home", .help = "Go to the start of the list." },
                .{ .keys = "End", .help = "Go to the end of the list." },
            };

            for (key_help, 0..) |help, i| {
                _ = try child.printSegment(
                    .{
                        .text = help.keys,
                        .style = ui_standard,
                    },
                    .{
                        .row_offset = i + 1,
                        .col_offset = 2,
                    },
                );
                _ = try child.printSegment(
                    .{
                        .text = "—",
                        .style = ui_standard,
                    },
                    .{
                        .row_offset = i + 1,
                        .col_offset = 15,
                    },
                );
                _ = try child.printSegment(
                    .{
                        .text = help.help,
                        .style = ui_standard,
                    },
                    .{
                        .row_offset = i + 1,
                        .col_offset = 17,
                    },
                );
            }
        }
    }

    pub fn drawPreview(self: *Preview, alloc: std.mem.Allocator, win: vaxis.Window, x_off: usize, ui_fg: vaxis.Color, ui_bg: vaxis.Color) !void {
        const width = win.width - x_off;

        const ui_err_fg: vaxis.Color = switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0xff, 0x00, 0x00 } },
            .dark => .{ .rgb = [_]u8{ 0xff, 0x00, 0x00 } },
        };

        const theme = self.themes[self.current];

        var config = try Config.default(alloc);
        defer config.deinit();

        config.loadFile(config._arena.?.allocator(), theme.path) catch |err| {
            const child = win.child(
                .{
                    .x_off = x_off,
                    .y_off = 0,
                    .width = .{
                        .limit = width,
                    },
                    .height = .{
                        .limit = win.height,
                    },
                },
            );
            child.fill(.{ .style = .{ .fg = ui_fg, .bg = ui_bg } });
            const middle = child.height / 2;
            {
                const text = try std.fmt.allocPrint(alloc, "Unable to open {s} from:", .{theme.theme});
                _ = try child.printSegment(
                    .{
                        .text = text,
                        .style = .{
                            .fg = ui_err_fg,
                            .bg = ui_bg,
                        },
                    },
                    .{
                        .row_offset = middle -| 1,
                        .col_offset = child.width / 2 -| text.len / 2,
                    },
                );
            }
            {
                _ = try child.printSegment(
                    .{
                        .text = theme.path,
                        .style = .{
                            .fg = ui_err_fg,
                            .bg = ui_bg,
                        },
                        .link = .{
                            .uri = try theme.toUri(alloc),
                        },
                    },
                    .{
                        .row_offset = middle,
                        .col_offset = child.width / 2 -| theme.path.len / 2,
                    },
                );
            }
            {
                const text = try std.fmt.allocPrint(alloc, "{}", .{err});
                _ = try child.printSegment(
                    .{
                        .text = text,
                        .style = .{
                            .fg = ui_err_fg,
                            .bg = ui_bg,
                        },
                    },
                    .{
                        .row_offset = middle + 1,
                        .col_offset = child.width / 2 -| text.len / 2,
                    },
                );
            }
            return;
        };

        var next_start: usize = 0;
        const fg: vaxis.Color = .{
            .rgb = [_]u8{
                config.foreground.r,
                config.foreground.g,
                config.foreground.b,
            },
        };
        const bg: vaxis.Color = .{
            .rgb = [_]u8{
                config.background.r,
                config.background.g,
                config.background.b,
            },
        };
        const standard: vaxis.Style = .{
            .fg = fg,
            .bg = bg,
        };
        const standard_bold: vaxis.Style = .{
            .fg = fg,
            .bg = bg,
            .bold = true,
        };
        const standard_italic: vaxis.Style = .{
            .fg = fg,
            .bg = bg,
            .italic = true,
        };
        const standard_bold_italic: vaxis.Style = .{
            .fg = fg,
            .bg = bg,
            .bold = true,
            .italic = true,
        };
        const standard_underline: vaxis.Style = .{
            .fg = fg,
            .bg = bg,
            .ul_style = .single,
        };
        const standard_double_underline: vaxis.Style = .{
            .fg = fg,
            .bg = bg,
            .ul_style = .double,
        };
        const standard_dashed_underline: vaxis.Style = .{
            .fg = fg,
            .bg = bg,
            .ul_style = .dashed,
        };
        const standard_curly_underline: vaxis.Style = .{
            .fg = fg,
            .bg = bg,
            .ul_style = .curly,
        };
        const standard_dotted_underline: vaxis.Style = .{
            .fg = fg,
            .bg = bg,
            .ul_style = .dotted,
        };

        {
            const child = win.child(
                .{
                    .x_off = x_off,
                    .y_off = next_start,
                    .width = .{
                        .limit = width,
                    },
                    .height = .{
                        .limit = 4,
                    },
                },
            );
            child.fill(.{ .style = standard });
            _ = try child.printSegment(
                .{
                    .text = theme.theme,
                    .style = standard_bold_italic,
                    .link = .{
                        .uri = try theme.toUri(alloc),
                    },
                },
                .{
                    .row_offset = 1,
                    .col_offset = child.width / 2 -| theme.theme.len / 2,
                },
            );
            _ = try child.printSegment(
                .{
                    .text = theme.path,
                    .style = standard,
                    .link = .{
                        .uri = try theme.toUri(alloc),
                    },
                },
                .{
                    .row_offset = 2,
                    .col_offset = child.width / 2 -| theme.path.len / 2,
                    .wrap = .none,
                },
            );
            next_start += child.height;
        }

        if (!config._errors.empty()) {
            const child = win.child(
                .{
                    .x_off = x_off,
                    .y_off = next_start,
                    .width = .{
                        .limit = width,
                    },
                    .height = .{
                        .limit = if (config._errors.empty()) 0 else 2 + config._errors.list.items.len,
                    },
                },
            );
            {
                const text = "Problems were encountered trying to load the theme:";
                _ = try child.printSegment(
                    .{
                        .text = text,
                        .style = .{
                            .fg = ui_err_fg,
                            .bg = ui_bg,
                        },
                    },
                    .{
                        .row_offset = 0,
                        .col_offset = child.width / 2 -| (text.len / 2),
                    },
                );
            }
            for (config._errors.list.items, 0..) |err, i| {
                _ = try child.printSegment(
                    .{
                        .text = err.message,
                        .style = .{
                            .fg = ui_err_fg,
                            .bg = ui_bg,
                        },
                    },
                    .{
                        .row_offset = 2 + i,
                        .col_offset = 2,
                    },
                );
            }
            next_start += child.height;
        }
        {
            const child = win.child(.{
                .x_off = x_off,
                .y_off = next_start,
                .width = .{
                    .limit = width,
                },
                .height = .{
                    .limit = 6,
                },
            });

            child.fill(.{ .style = standard });

            for (0..16) |i| {
                const r = i / 8;
                const c = i % 8;
                const text = if (self.hex)
                    try std.fmt.allocPrint(alloc, " {x:0>2}", .{i})
                else
                    try std.fmt.allocPrint(alloc, "{d:3}", .{i});
                _ = try child.printSegment(
                    .{
                        .text = text,
                        .style = standard,
                    },
                    .{
                        .row_offset = 3 * r,
                        .col_offset = c * 8,
                    },
                );
                _ = try child.printSegment(
                    .{
                        .text = "████",
                        .style = .{
                            .fg = color(config, i),
                            .bg = bg,
                        },
                    },
                    .{
                        .row_offset = 3 * r,
                        .col_offset = 4 + c * 8,
                    },
                );
                _ = try child.printSegment(
                    .{
                        .text = "████",
                        .style = .{
                            .fg = color(config, i),
                            .bg = bg,
                        },
                    },
                    .{
                        .row_offset = 3 * r + 1,
                        .col_offset = 4 + c * 8,
                    },
                );
            }
            next_start += child.height;
        }
        {
            const child = win.child(
                .{
                    .x_off = x_off,
                    .y_off = next_start,
                    .width = .{
                        .limit = width,
                    },
                    .height = .{
                        .limit = 24,
                    },
                },
            );
            const bold: vaxis.Style = .{
                .fg = fg,
                .bg = bg,
                .bold = true,
            };
            const color1: vaxis.Style = .{
                .fg = color(config, 1),
                .bg = bg,
            };
            const color2: vaxis.Style = .{
                .fg = color(config, 2),
                .bg = bg,
            };
            const color3: vaxis.Style = .{
                .fg = color(config, 3),
                .bg = bg,
            };
            const color4: vaxis.Style = .{
                .fg = color(config, 4),
                .bg = bg,
            };
            const color5: vaxis.Style = .{
                .fg = color(config, 5),
                .bg = bg,
            };
            const color6: vaxis.Style = .{
                .fg = color(config, 6),
                .bg = bg,
            };
            const color6ul: vaxis.Style = .{
                .fg = color(config, 6),
                .bg = bg,
                .ul_style = .single,
            };
            const color10: vaxis.Style = .{
                .fg = color(config, 10),
                .bg = bg,
            };
            const color12: vaxis.Style = .{
                .fg = color(config, 12),
                .bg = bg,
            };
            const color238: vaxis.Style = .{
                .fg = color(config, 238),
                .bg = bg,
            };
            child.fill(.{ .style = standard });
            _ = try child.print(
                &.{
                    .{ .text = "→", .style = color2 },
                    .{ .text = " ", .style = standard },
                    .{ .text = "bat", .style = color4 },
                    .{ .text = " ", .style = standard },
                    .{ .text = "ziggzagg.zig", .style = color6ul },
                },
                .{
                    .row_offset = 0,
                    .col_offset = 2,
                },
            );
            {
                _ = try child.print(
                    &.{
                        .{
                            .text = "───────┬",
                            .style = color238,
                        },
                    },
                    .{
                        .row_offset = 1,
                        .col_offset = 2,
                    },
                );
                for (10..child.width) |col| {
                    _ = try child.print(
                        &.{
                            .{
                                .text = "─",
                                .style = color238,
                            },
                        },
                        .{
                            .row_offset = 1,
                            .col_offset = col,
                        },
                    );
                }
            }
            _ = try child.print(
                &.{
                    .{
                        .text = "       │ ",
                        .style = color238,
                    },

                    .{
                        .text = "File: ",
                        .style = standard,
                    },

                    .{
                        .text = "ziggzag.zig",
                        .style = bold,
                    },
                },
                .{
                    .row_offset = 2,
                    .col_offset = 2,
                },
            );
            {
                _ = try child.print(
                    &.{
                        .{
                            .text = "───────┼",
                            .style = color238,
                        },
                    },
                    .{
                        .row_offset = 3,
                        .col_offset = 2,
                    },
                );
                for (10..child.width) |col| {
                    _ = try child.print(
                        &.{
                            .{
                                .text = "─",
                                .style = color238,
                            },
                        },
                        .{
                            .row_offset = 3,
                            .col_offset = col,
                        },
                    );
                }
            }
            _ = try child.print(
                &.{
                    .{ .text = "   1   │ ", .style = color238 },
                    .{ .text = "const", .style = color5 },
                    .{ .text = " std ", .style = standard },
                    .{ .text = "= @import", .style = color5 },
                    .{ .text = "(", .style = standard },
                    .{ .text = "\"std\"", .style = color10 },
                    .{ .text = ");", .style = standard },
                },
                .{
                    .row_offset = 4,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "   2   │", .style = color238 },
                },
                .{
                    .row_offset = 5,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "   3   │ ", .style = color238 },
                    .{ .text = "pub ", .style = color5 },
                    .{ .text = "fn ", .style = color12 },
                    .{ .text = "main", .style = color2 },
                    .{ .text = "() ", .style = standard },
                    .{ .text = "!", .style = color5 },
                    .{ .text = "void", .style = color12 },
                    .{ .text = " {", .style = standard },
                },
                .{
                    .row_offset = 6,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "   4   │     ", .style = color238 },
                    .{ .text = "const ", .style = color5 },
                    .{ .text = "stdout ", .style = standard },
                    .{ .text = "=", .style = color5 },
                    .{ .text = " std.io.getStdOut().writer();", .style = standard },
                },
                .{
                    .row_offset = 7,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "   5   │     ", .style = color238 },
                    .{ .text = "var ", .style = color5 },
                    .{ .text = "i:", .style = standard },
                    .{ .text = " usize", .style = color12 },
                    .{ .text = " =", .style = color5 },
                    .{ .text = " 1", .style = color4 },
                    .{ .text = ";", .style = standard },
                },
                .{
                    .row_offset = 8,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "   6   │     ", .style = color238 },
                    .{ .text = "while ", .style = color5 },
                    .{ .text = "(i ", .style = standard },
                    .{ .text = "<= ", .style = color5 },
                    .{ .text = "16", .style = color4 },
                    .{ .text = ") : (i ", .style = standard },
                    .{ .text = "+= ", .style = color5 },
                    .{ .text = "1", .style = color4 },
                    .{ .text = ") {", .style = standard },
                },
                .{
                    .row_offset = 9,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "   7   │         ", .style = color238 },
                    .{ .text = "if ", .style = color5 },
                    .{ .text = "(i ", .style = standard },
                    .{ .text = "% ", .style = color5 },
                    .{ .text = "15 ", .style = color4 },
                    .{ .text = "== ", .style = color5 },
                    .{ .text = "0", .style = color4 },
                    .{ .text = ") {", .style = standard },
                },
                .{
                    .row_offset = 10,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "   8   │             ", .style = color238 },
                    .{ .text = "try ", .style = color5 },
                    .{ .text = "stdout.writeAll(", .style = standard },
                    .{ .text = "\"ZiggZagg", .style = color10 },
                    .{ .text = "\\n", .style = color12 },
                    .{ .text = "\"", .style = color10 },
                    .{ .text = ");", .style = standard },
                },
                .{
                    .row_offset = 11,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "   9   │         ", .style = color238 },
                    .{ .text = "} ", .style = standard },
                    .{ .text = "else if ", .style = color5 },
                    .{ .text = "(i ", .style = standard },
                    .{ .text = "% ", .style = color5 },
                    .{ .text = "3 ", .style = color4 },
                    .{ .text = "== ", .style = color5 },
                    .{ .text = "0", .style = color4 },
                    .{ .text = ") {", .style = standard },
                },
                .{
                    .row_offset = 12,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "  10   │             ", .style = color238 },
                    .{ .text = "try ", .style = color5 },
                    .{ .text = "stdout.writeAll(", .style = standard },
                    .{ .text = "\"Zigg", .style = color10 },
                    .{ .text = "\\n", .style = color12 },
                    .{ .text = "\"", .style = color10 },
                    .{ .text = ");", .style = standard },
                },
                .{
                    .row_offset = 13,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "  11   │         ", .style = color238 },
                    .{ .text = "} ", .style = standard },
                    .{ .text = "else if ", .style = color5 },
                    .{ .text = "(i ", .style = standard },
                    .{ .text = "% ", .style = color5 },
                    .{ .text = "5 ", .style = color4 },
                    .{ .text = "== ", .style = color5 },
                    .{ .text = "0", .style = color4 },
                    .{ .text = ") {", .style = standard },
                },
                .{
                    .row_offset = 14,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "  12   │             ", .style = color238 },
                    .{ .text = "try ", .style = color5 },
                    .{ .text = "stdout.writeAll(", .style = standard },
                    .{ .text = "\"Zagg", .style = color10 },
                    .{ .text = "\\n", .style = color12 },
                    .{ .text = "\"", .style = color10 },
                    .{ .text = ");", .style = standard },
                },
                .{
                    .row_offset = 15,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "  13   │         ", .style = color238 },
                    .{ .text = "} ", .style = standard },
                    .{ .text = "else ", .style = color5 },
                    .{ .text = "{", .style = standard },
                },
                .{
                    .row_offset = 16,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "  14   │             ", .style = color238 },
                    .{ .text = "try ", .style = color5 },
                    .{ .text = "stdout.print(", .style = standard },
                    .{ .text = "\"{d}", .style = color10 },
                    .{ .text = "\\n", .style = color12 },
                    .{ .text = "\"", .style = color10 },
                    .{ .text = ", .{i});", .style = standard },
                },
                .{
                    .row_offset = 17,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "  15   │         ", .style = color238 },
                    .{ .text = "}", .style = standard },
                },
                .{
                    .row_offset = 18,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "  16   │     ", .style = color238 },
                    .{ .text = "}", .style = standard },
                },
                .{
                    .row_offset = 19,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "  17   │ ", .style = color238 },
                    .{ .text = "}", .style = standard },
                },
                .{
                    .row_offset = 20,
                    .col_offset = 2,
                },
            );
            {
                _ = try child.print(
                    &.{
                        .{
                            .text = "───────┴",
                            .style = color238,
                        },
                    },
                    .{
                        .row_offset = 21,
                        .col_offset = 2,
                    },
                );
                for (10..child.width) |col| {
                    _ = try child.print(
                        &.{
                            .{
                                .text = "─",
                                .style = color238,
                            },
                        },
                        .{
                            .row_offset = 21,
                            .col_offset = col,
                        },
                    );
                }
            }
            _ = try child.print(
                &.{
                    .{ .text = "ghostty ", .style = color6 },
                    .{ .text = "on ", .style = standard },
                    .{ .text = " main ", .style = color4 },
                    .{ .text = "[+] ", .style = color1 },
                    .{ .text = "via ", .style = standard },
                    .{ .text = " v0.13.0 ", .style = color3 },
                    .{ .text = "via ", .style = standard },
                    .{ .text = "  impure (ghostty-env)", .style = color4 },
                },
                .{
                    .row_offset = 22,
                    .col_offset = 2,
                },
            );
            _ = try child.print(
                &.{
                    .{ .text = "✦ ", .style = color4 },
                    .{ .text = "at ", .style = standard },
                    .{ .text = "10:36:15 ", .style = color3 },
                    .{ .text = "→", .style = color2 },
                },
                .{
                    .row_offset = 23,
                    .col_offset = 2,
                },
            );
            next_start += child.height;
        }
        if (next_start < win.height) {
            const child = win.child(
                .{
                    .x_off = x_off,
                    .y_off = next_start,
                    .width = .{
                        .limit = width,
                    },
                    .height = .{
                        .limit = win.height - next_start,
                    },
                },
            );
            child.fill(.{ .style = standard });
            var it = std.mem.splitAny(u8, lorem_ipsum, " \n");
            var row: usize = 1;
            var col: usize = 2;
            while (row < child.height) {
                const word = it.next() orelse line: {
                    it.reset();
                    break :line it.next() orelse unreachable;
                };
                if (col + word.len > child.width) {
                    row += 1;
                    col = 2;
                }
                const style: vaxis.Style = style: {
                    if (std.mem.eql(u8, "ipsum", word)) break :style .{ .fg = color(config, 2), .bg = bg };
                    if (std.mem.eql(u8, "consectetur", word)) break :style standard_bold;
                    if (std.mem.eql(u8, "reprehenderit", word)) break :style standard_italic;
                    if (std.mem.eql(u8, "Praesent", word)) break :style standard_bold_italic;
                    if (std.mem.eql(u8, "auctor", word)) break :style standard_underline;
                    if (std.mem.eql(u8, "dui", word)) break :style standard_double_underline;
                    if (std.mem.eql(u8, "erat", word)) break :style standard_dashed_underline;
                    if (std.mem.eql(u8, "enim", word)) break :style standard_dotted_underline;
                    if (std.mem.eql(u8, "odio", word)) break :style standard_curly_underline;
                    break :style standard;
                };
                _ = try child.printSegment(
                    .{
                        .text = word,
                        .style = style,
                    },
                    .{
                        .row_offset = row,
                        .col_offset = col,
                    },
                );
                col += word.len + 1;
            }
        }
    }
};

fn color(config: Config, palette: usize) vaxis.Color {
    return .{
        .rgb = [_]u8{
            config.palette.value[palette].r,
            config.palette.value[palette].g,
            config.palette.value[palette].b,
        },
    };
}

const lorem_ipsum = @embedFile("lorem_ipsum.txt");

fn preview(allocator: std.mem.Allocator, themes: []ThemeListElement) !void {
    var app = try Preview.init(allocator, themes);
    defer app.deinit();
    try app.run();
}
