//! The primary terminal emulation structure. This represents a single
//!
//! "terminal" containing a grid of characters and exposes various operations
//! on that grid. This also maintains the scrollback buffer.
const Terminal = @This();

const std = @import("std");
const builtin = @import("builtin");
const utf8proc = @import("utf8proc");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const ansi = @import("ansi.zig");
const modes = @import("modes.zig");
const charsets = @import("charsets.zig");
const csi = @import("csi.zig");
const kitty = @import("kitty.zig");
const sgr = @import("sgr.zig");
const Tabstops = @import("Tabstops.zig");
const trace = @import("tracy").trace;
const color = @import("color.zig");
const Screen = @import("Screen.zig");

const log = std.log.scoped(.terminal);

/// Default tabstop interval
const TABSTOP_INTERVAL = 8;

/// Screen type is an enum that tracks whether a screen is primary or alternate.
pub const ScreenType = enum {
    primary,
    alternate,
};

/// The semantic prompt type. This is used when tracking a line type and
/// requires integration with the shell. By default, we mark a line as "none"
/// meaning we don't know what type it is.
///
/// See: https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md
pub const SemanticPrompt = enum {
    prompt,
    prompt_continuation,
    input,
    command,
};

/// Screen is the current screen state. The "active_screen" field says what
/// the current screen is. The backup screen is the opposite of the active
/// screen.
active_screen: ScreenType,
screen: Screen,
secondary_screen: Screen,

/// Whether we're currently writing to the status line (DECSASD and DECSSDT).
/// We don't support a status line currently so we just black hole this
/// data so that it doesn't mess up our main display.
status_display: ansi.StatusDisplay = .main,

/// Where the tabstops are.
tabstops: Tabstops,

/// The size of the terminal.
rows: usize,
cols: usize,

/// The size of the screen in pixels. This is used for pty events and images
width_px: u32 = 0,
height_px: u32 = 0,

/// The current scrolling region.
scrolling_region: ScrollingRegion,

/// The last reported pwd, if any.
pwd: std.ArrayList(u8),

/// The color palette to use
color_palette: color.Palette = color.default,

/// The previous printed character. This is used for the repeat previous
/// char CSI (ESC [ <n> b).
previous_char: ?u21 = null,

/// The modes that this terminal currently has active.
modes: modes.ModeState = .{},

/// These are just a packed set of flags we may set on the terminal.
flags: packed struct {
    // This isn't a mode, this is set by OSC 133 using the "A" event.
    // If this is true, it tells us that the shell supports redrawing
    // the prompt and that when we resize, if the cursor is at a prompt,
    // then we should clear the screen below and allow the shell to redraw.
    shell_redraws_prompt: bool = false,

    // This is set via ESC[4;2m. Any other modify key mode just sets
    // this to false and we act in mode 1 by default.
    modify_other_keys_2: bool = false,

    /// The mouse event mode and format. These are set to the last
    /// set mode in modes. You can't get the right event/format to use
    /// based on modes alone because modes don't show you what order
    /// this was called so we have to track it separately.
    mouse_event: MouseEvents = .none,
    mouse_format: MouseFormat = .x10,
} = .{},

/// The event types that can be reported for mouse-related activities.
/// These are all mutually exclusive (hence in a single enum).
pub const MouseEvents = enum(u3) {
    none = 0,
    x10 = 1, // 9
    normal = 2, // 1000
    button = 3, // 1002
    any = 4, // 1003

    /// Returns true if this event sends motion events.
    pub fn motion(self: MouseEvents) bool {
        return self == .button or self == .any;
    }
};

/// The format of mouse events when enabled.
/// These are all mutually exclusive (hence in a single enum).
pub const MouseFormat = enum(u3) {
    x10 = 0,
    utf8 = 1, // 1005
    sgr = 2, // 1006
    urxvt = 3, // 1015
    sgr_pixels = 4, // 1016
};

/// Scrolling region is the area of the screen designated where scrolling
/// occurs. Wen scrolling the screen, only this viewport is scrolled.
const ScrollingRegion = struct {
    // Top and bottom of the scroll region (0-indexed)
    // Precondition: top < bottom
    top: usize,
    bottom: usize,

    // Left/right scroll regions.
    // Precondition: right > left
    // Precondition: right <= cols - 1
    left: usize,
    right: usize,
};

/// Initialize a new terminal.
pub fn init(alloc: Allocator, cols: usize, rows: usize) !Terminal {
    return Terminal{
        .cols = cols,
        .rows = rows,
        .active_screen = .primary,
        // TODO: configurable scrollback
        .screen = try Screen.init(alloc, rows, cols, 10000),
        // No scrollback for the alternate screen
        .secondary_screen = try Screen.init(alloc, rows, cols, 0),
        .tabstops = try Tabstops.init(alloc, cols, TABSTOP_INTERVAL),
        .scrolling_region = .{
            .top = 0,
            .bottom = rows - 1,
            .left = 0,
            .right = cols - 1,
        },
        .pwd = std.ArrayList(u8).init(alloc),
    };
}

pub fn deinit(self: *Terminal, alloc: Allocator) void {
    self.tabstops.deinit(alloc);
    self.screen.deinit();
    self.secondary_screen.deinit();
    self.pwd.deinit();
    self.* = undefined;
}

/// Options for switching to the alternate screen.
pub const AlternateScreenOptions = struct {
    cursor_save: bool = false,
    clear_on_enter: bool = false,
    clear_on_exit: bool = false,
};

/// Switch to the alternate screen buffer.
///
/// The alternate screen buffer:
///   * has its own grid
///   * has its own cursor state (included saved cursor)
///   * does not support scrollback
///
pub fn alternateScreen(
    self: *Terminal,
    alloc: Allocator,
    options: AlternateScreenOptions,
) void {
    const tracy = trace(@src());
    defer tracy.end();

    //log.info("alt screen active={} options={} cursor={}", .{ self.active_screen, options, self.screen.cursor });

    // TODO: test
    // TODO(mitchellh): what happens if we enter alternate screen multiple times?
    // for now, we ignore...
    if (self.active_screen == .alternate) return;

    // If we requested cursor save, we save the cursor in the primary screen
    if (options.cursor_save) self.saveCursor();

    // Switch the screens
    const old = self.screen;
    self.screen = self.secondary_screen;
    self.secondary_screen = old;
    self.active_screen = .alternate;

    // Bring our pen with us
    self.screen.cursor = old.cursor;

    // Bring our charset state with us
    self.screen.charset = old.charset;

    // Clear our selection
    self.screen.selection = null;

    if (options.clear_on_enter) {
        self.eraseDisplay(alloc, .complete, false);
    }
}

/// Switch back to the primary screen (reset alternate screen mode).
pub fn primaryScreen(
    self: *Terminal,
    alloc: Allocator,
    options: AlternateScreenOptions,
) void {
    const tracy = trace(@src());
    defer tracy.end();

    //log.info("primary screen active={} options={}", .{ self.active_screen, options });

    // TODO: test
    // TODO(mitchellh): what happens if we enter alternate screen multiple times?
    if (self.active_screen == .primary) return;

    if (options.clear_on_exit) self.eraseDisplay(alloc, .complete, false);

    // Switch the screens
    const old = self.screen;
    self.screen = self.secondary_screen;
    self.secondary_screen = old;
    self.active_screen = .primary;

    // Clear our selection
    self.screen.selection = null;

    // Restore the cursor from the primary screen
    if (options.cursor_save) self.restoreCursor();
}

/// The modes for DECCOLM.
pub const DeccolmMode = enum(u1) {
    @"80_cols" = 0,
    @"132_cols" = 1,
};

/// DECCOLM changes the terminal width between 80 and 132 columns. This
/// function call will do NOTHING unless `setDeccolmSupported` has been
/// called with "true".
///
/// This breaks the expectation around modern terminals that they resize
/// with the window. This will fix the grid at either 80 or 132 columns.
/// The rows will continue to be variable.
pub fn deccolm(self: *Terminal, alloc: Allocator, mode: DeccolmMode) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // TODO: test

    // We need to support this. This corresponds to xterm's private mode 40
    // bit. If the mode "?40" is set, then "?3" (DECCOLM) is supported. This
    // doesn't exactly match VT100 semantics but modern terminals no longer
    // blindly accept mode 3 since its so weird in modern practice.
    if (!self.modes.get(.enable_mode_3)) return;

    // Enable it
    self.modes.set(.@"132_column", mode == .@"132_cols");

    // Resize -- we can set cols to 0 because deccolm will force it
    try self.resize(alloc, 0, self.rows);

    // TODO: do not clear screen flag mode
    self.eraseDisplay(alloc, .complete, false);
    self.setCursorPos(1, 1);

    // TODO: left/right margins
}

/// Resize the underlying terminal.
pub fn resize(self: *Terminal, alloc: Allocator, cols_req: usize, rows: usize) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // If we have deccolm supported then we are fixed at either 80 or 132
    // columns depending on if mode 3 is set or not.
    // TODO: test
    const cols: usize = if (self.modes.get(.enable_mode_3))
        if (self.modes.get(.@"132_column")) 132 else 80
    else
        cols_req;

    // If our cols/rows didn't change then we're done
    if (self.cols == cols and self.rows == rows) return;

    // Resize our tabstops
    // TODO: use resize, but it doesn't set new tabstops
    if (self.cols != cols) {
        self.tabstops.deinit(alloc);
        self.tabstops = try Tabstops.init(alloc, cols, 8);
    }

    // If we're making the screen smaller, dealloc the unused items.
    if (self.active_screen == .primary) {
        self.clearPromptForResize();
        try self.screen.resize(rows, cols);
        try self.secondary_screen.resizeWithoutReflow(rows, cols);
    } else {
        try self.screen.resizeWithoutReflow(rows, cols);
        try self.secondary_screen.resize(rows, cols);
    }

    // Set our size
    self.cols = cols;
    self.rows = rows;

    // Reset the scrolling region
    self.scrolling_region = .{
        .top = 0,
        .bottom = rows - 1,
        .left = 0,
        .right = cols - 1,
    };
}

/// If shell_redraws_prompt is true and we're on the primary screen,
/// then this will clear the screen from the cursor down if the cursor is
/// on a prompt in order to allow the shell to redraw the prompt.
fn clearPromptForResize(self: *Terminal) void {
    assert(self.active_screen == .primary);

    if (!self.flags.shell_redraws_prompt) return;

    // We need to find the first y that is a prompt. If we find any line
    // that is NOT a prompt (or input -- which is part of a prompt) then
    // we are not at a prompt and we can exit this function.
    const prompt_y: usize = prompt_y: {
        // Keep track of the found value, because we want to find the START
        var found: ?usize = null;

        // Search from the cursor up
        var y: usize = 0;
        while (y <= self.screen.cursor.y) : (y += 1) {
            const real_y = self.screen.cursor.y - y;
            const row = self.screen.getRow(.{ .active = real_y });
            switch (row.getSemanticPrompt()) {
                // We are at a prompt but we're not at the start of the prompt.
                // We mark our found value and continue because the prompt
                // may be multi-line.
                .input => found = real_y,

                // If we find the prompt then we're done. We are also done
                // if we find any prompt continuation, because the shells
                // that send this currently (zsh) cannot redraw every line.
                .prompt, .prompt_continuation => {
                    found = real_y;
                    break;
                },

                // If we have command output, then we're most certainly not
                // at a prompt. Break out of the loop.
                .command => break,

                // If we don't know, we keep searching.
                .unknown => {},
            }
        }

        if (found) |found_y| break :prompt_y found_y;
        return;
    };
    assert(prompt_y < self.rows);

    // We want to clear all the lines from prompt_y downwards because
    // the shell will redraw the prompt.
    for (prompt_y..self.rows) |y| {
        const row = self.screen.getRow(.{ .active = y });
        row.setWrapped(false);
        row.setDirty(true);
        row.clear(.{});
    }
}

/// Return the current string value of the terminal. Newlines are
/// encoded as "\n". This omits any formatting such as fg/bg.
///
/// The caller must free the string.
fn plainString(self: *Terminal, alloc: Allocator) ![]const u8 {
    return try self.screen.testString(alloc, .viewport);
}

/// Save cursor position and further state.
///
/// The primary and alternate screen have distinct save state. One saved state
/// is kept per screen (main / alternative). If for the current screen state
/// was already saved it is overwritten.
pub fn saveCursor(self: *Terminal) void {
    self.screen.saved_cursor = self.screen.cursor;
    self.screen.saved_charset = self.screen.charset;
    self.screen.saved_origin_mode = self.modes.get(.origin);
}

/// Restore cursor position and other state.
///
/// The primary and alternate screen have distinct save state.
/// If no save was done before values are reset to their initial values.
pub fn restoreCursor(self: *Terminal) void {
    self.screen.cursor = self.screen.saved_cursor;
    self.screen.charset = self.screen.saved_charset;
    self.modes.set(.origin, self.screen.saved_origin_mode);
}

/// TODO: test
pub fn setAttribute(self: *Terminal, attr: sgr.Attribute) !void {
    const tracy = trace(@src());
    defer tracy.end();

    switch (attr) {
        .unset => {
            self.screen.cursor.pen.attrs.has_fg = false;
            self.screen.cursor.pen.attrs.has_bg = false;
            self.screen.cursor.pen.attrs = .{};
        },

        .bold => {
            self.screen.cursor.pen.attrs.bold = true;
        },

        .reset_bold => {
            // Bold and faint share the same SGR code for this
            self.screen.cursor.pen.attrs.bold = false;
            self.screen.cursor.pen.attrs.faint = false;
        },

        .italic => {
            self.screen.cursor.pen.attrs.italic = true;
        },

        .reset_italic => {
            self.screen.cursor.pen.attrs.italic = false;
        },

        .faint => {
            self.screen.cursor.pen.attrs.faint = true;
        },

        .underline => |v| {
            self.screen.cursor.pen.attrs.underline = v;
        },

        .reset_underline => {
            self.screen.cursor.pen.attrs.underline = .none;
        },

        .underline_color => |rgb| {
            self.screen.cursor.pen.attrs.underline_color = true;
            self.screen.cursor.pen.underline_fg = .{
                .r = rgb.r,
                .g = rgb.g,
                .b = rgb.b,
            };
        },

        .reset_underline_color => {
            self.screen.cursor.pen.attrs.underline_color = false;
        },

        .blink => {
            log.warn("blink requested, but not implemented", .{});
            self.screen.cursor.pen.attrs.blink = true;
        },

        .reset_blink => {
            self.screen.cursor.pen.attrs.blink = false;
        },

        .inverse => {
            self.screen.cursor.pen.attrs.inverse = true;
        },

        .reset_inverse => {
            self.screen.cursor.pen.attrs.inverse = false;
        },

        .invisible => {
            self.screen.cursor.pen.attrs.invisible = true;
        },

        .reset_invisible => {
            self.screen.cursor.pen.attrs.invisible = false;
        },

        .strikethrough => {
            self.screen.cursor.pen.attrs.strikethrough = true;
        },

        .reset_strikethrough => {
            self.screen.cursor.pen.attrs.strikethrough = false;
        },

        .direct_color_fg => |rgb| {
            self.screen.cursor.pen.attrs.has_fg = true;
            self.screen.cursor.pen.fg = .{
                .r = rgb.r,
                .g = rgb.g,
                .b = rgb.b,
            };
        },

        .direct_color_bg => |rgb| {
            self.screen.cursor.pen.attrs.has_bg = true;
            self.screen.cursor.pen.bg = .{
                .r = rgb.r,
                .g = rgb.g,
                .b = rgb.b,
            };
        },

        .@"8_fg" => |n| {
            self.screen.cursor.pen.attrs.has_fg = true;
            self.screen.cursor.pen.fg = self.color_palette[@intFromEnum(n)];
        },

        .@"8_bg" => |n| {
            self.screen.cursor.pen.attrs.has_bg = true;
            self.screen.cursor.pen.bg = self.color_palette[@intFromEnum(n)];
        },

        .reset_fg => self.screen.cursor.pen.attrs.has_fg = false,

        .reset_bg => self.screen.cursor.pen.attrs.has_bg = false,

        .@"8_bright_fg" => |n| {
            self.screen.cursor.pen.attrs.has_fg = true;
            self.screen.cursor.pen.fg = self.color_palette[@intFromEnum(n)];
        },

        .@"8_bright_bg" => |n| {
            self.screen.cursor.pen.attrs.has_bg = true;
            self.screen.cursor.pen.bg = self.color_palette[@intFromEnum(n)];
        },

        .@"256_fg" => |idx| {
            self.screen.cursor.pen.attrs.has_fg = true;
            self.screen.cursor.pen.fg = self.color_palette[idx];
        },

        .@"256_bg" => |idx| {
            self.screen.cursor.pen.attrs.has_bg = true;
            self.screen.cursor.pen.bg = self.color_palette[idx];
        },

        .unknown => return error.InvalidAttribute,
    }
}

/// Set the charset into the given slot.
pub fn configureCharset(self: *Terminal, slot: charsets.Slots, set: charsets.Charset) void {
    self.screen.charset.charsets.set(slot, set);
}

/// Invoke the charset in slot into the active slot. If single is true,
/// then this will only be invoked for a single character.
pub fn invokeCharset(
    self: *Terminal,
    active: charsets.ActiveSlot,
    slot: charsets.Slots,
    single: bool,
) void {
    if (single) {
        assert(active == .GL);
        self.screen.charset.single_shift = slot;
        return;
    }

    switch (active) {
        .GL => self.screen.charset.gl = slot,
        .GR => self.screen.charset.gr = slot,
    }
}

/// Print UTF-8 encoded string to the terminal. This string must be
/// a single line, newlines and carriage returns and other control
/// characters are not processed.
///
/// This is not public because it is only used for tests rigt now.
fn printString(self: *Terminal, str: []const u8) !void {
    const view = try std.unicode.Utf8View.init(str);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| try self.print(cp);
}

pub fn print(self: *Terminal, c: u21) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // If we're not on the main display, do nothing for now
    if (self.status_display != .main) return;

    // Perform grapheme clustering if grapheme support is enabled (mode 2027).
    // This is MUCH slower than the normal path so the conditional below is
    // purposely ordered in least-likely to most-likely so we can drop out
    // as quickly as possible.
    if (c > 255 and
        self.modes.get(.grapheme_cluster) and
        self.screen.cursor.x > 0)
    {
        const row = self.screen.getRow(.{ .active = self.screen.cursor.y });

        // We need the previous cell to determine if we're at a grapheme
        // break or not. If we are NOT, then we are still combining the
        // same grapheme. Otherwise, we can stay in this cell.
        const Prev = struct { cell: *Screen.Cell, x: usize };
        const prev: Prev = prev: {
            const x = self.screen.cursor.x - 1;
            const immediate = row.getCellPtr(x);

            // If the previous cell is a wide spacer tail, then we actually
            // want to use the cell before that because that has the actual
            // content.
            if (!immediate.attrs.wide_spacer_tail) break :prev .{
                .cell = immediate,
                .x = x,
            };

            break :prev .{
                .cell = row.getCellPtr(x - 1),
                .x = x - 1,
            };
        };

        const grapheme_break = brk: {
            var state: i32 = 0;
            var cp1 = @as(u21, @intCast(prev.cell.char));
            if (prev.cell.attrs.grapheme) {
                var it = row.codepointIterator(prev.x);
                while (it.next()) |cp2| {
                    assert(!utf8proc.graphemeBreakStateful(
                        cp1,
                        cp2,
                        &state,
                    ));

                    cp1 = cp2;
                }
            }

            break :brk utf8proc.graphemeBreakStateful(cp1, c, &state);
        };

        // If we can NOT break, this means that "c" is part of a grapheme
        // with the previous char.
        if (!grapheme_break) {
            log.debug("c={x} grapheme attach to x={}", .{ c, prev.x });
            try row.attachGrapheme(prev.x, c);
            return;
        }
    }

    // Determine the width of this character so we can handle
    // non-single-width characters properly.
    const width = utf8proc.charwidth(c);
    assert(width <= 2);

    // Attach zero-width characters to our cell as grapheme data.
    if (width == 0) {
        // If we're at cell zero, then this is malformed data and we don't
        // print anything or even store this. Zero-width characters are ALWAYS
        // attached to some other non-zero-width character at the time of
        // writing.
        if (self.screen.cursor.x == 0) {
            log.warn("zero-width character with no prior character, ignoring", .{});
            return;
        }

        // Find our previous cell
        const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
        const prev: usize = prev: {
            const x = self.screen.cursor.x - 1;
            const immediate = row.getCellPtr(x);
            if (!immediate.attrs.wide_spacer_tail) break :prev x;
            break :prev x - 1;
        };

        try row.attachGrapheme(prev, c);
        return;
    }

    // We have a printable character, save it
    self.previous_char = c;

    // If we're soft-wrapping, then handle that first.
    if (self.screen.cursor.pending_wrap and self.modes.get(.wraparound))
        try self.printWrap();

    // If we have insert mode enabled then we need to handle that. We
    // only do insert mode if we're not at the end of the line.
    if (self.modes.get(.insert) and
        self.screen.cursor.x + width < self.cols)
    {
        self.insertBlanks(width);
    }

    switch (width) {
        // Single cell is very easy: just write in the cell
        1 => _ = @call(.always_inline, printCell, .{ self, c }),

        // Wide character requires a spacer. We print this by
        // using two cells: the first is flagged "wide" and has the
        // wide char. The second is guaranteed to be a spacer if
        // we're not at the end of the line.
        2 => if (self.cols > 1) {
            // If we don't have space for the wide char, we need
            // to insert spacers and wrap. Then we just print the wide
            // char as normal.
            if (self.screen.cursor.x == self.cols - 1) {
                const spacer_head = self.printCell(' ');
                spacer_head.attrs.wide_spacer_head = true;
                try self.printWrap();
            }

            const wide_cell = self.printCell(c);
            wide_cell.attrs.wide = true;

            // Write our spacer
            self.screen.cursor.x += 1;
            const spacer = self.printCell(' ');
            spacer.attrs.wide_spacer_tail = true;
        } else {
            // This is pretty broken, terminals should never be only 1-wide.
            // We sould prevent this downstream.
            _ = self.printCell(' ');
        },

        else => unreachable,
    }

    // Move the cursor
    self.screen.cursor.x += 1;

    // If we're at the column limit, then we need to wrap the next time.
    // This is unlikely so we do the increment above and decrement here
    // if we need to rather than check once.
    if (self.screen.cursor.x == self.cols) {
        self.screen.cursor.x -= 1;
        self.screen.cursor.pending_wrap = true;
    }
}

fn printCell(self: *Terminal, unmapped_c: u21) *Screen.Cell {
    // const tracy = trace(@src());
    // defer tracy.end();

    const c: u21 = c: {
        // TODO: non-utf8 handling, gr

        // If we're single shifting, then we use the key exactly once.
        const key = if (self.screen.charset.single_shift) |key_once| blk: {
            self.screen.charset.single_shift = null;
            break :blk key_once;
        } else self.screen.charset.gl;
        const set = self.screen.charset.charsets.get(key);

        // UTF-8 or ASCII is used as-is
        if (set == .utf8 or set == .ascii) break :c unmapped_c;

        // If we're outside of ASCII range this is an invalid value in
        // this table so we just return space.
        if (unmapped_c > std.math.maxInt(u8)) break :c ' ';

        // Get our lookup table and map it
        const table = set.table();
        break :c @intCast(table[@intCast(unmapped_c)]);
    };

    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
    const cell = row.getCellPtr(self.screen.cursor.x);

    // If this cell is wide char then we need to clear it.
    // We ignore wide spacer HEADS because we can just write
    // single-width characters into that.
    if (cell.attrs.wide) {
        const x = self.screen.cursor.x + 1;
        assert(x < self.cols);

        const spacer_cell = row.getCellPtr(x);
        spacer_cell.attrs.wide_spacer_tail = false;

        if (self.screen.cursor.y > 0 and self.screen.cursor.x <= 1) {
            self.clearWideSpacerHead();
        }
    } else if (cell.attrs.wide_spacer_tail) {
        assert(self.screen.cursor.x > 0);
        const x = self.screen.cursor.x - 1;

        const wide_cell = row.getCellPtr(x);
        wide_cell.attrs.wide = false;

        if (self.screen.cursor.x <= 1) {
            self.clearWideSpacerHead();
        }
    }

    // If the prior value had graphemes, clear those
    if (cell.attrs.grapheme) row.clearGraphemes(self.screen.cursor.x);

    // Write
    cell.* = self.screen.cursor.pen;
    cell.char = @intCast(c);
    return cell;
}

fn printWrap(self: *Terminal) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
    row.setWrapped(true);

    // Move to the next line
    try self.index();
    self.screen.cursor.x = 0;
}

fn clearWideSpacerHead(self: *Terminal) void {
    // TODO: handle deleting wide char on row 0 of active
    assert(self.screen.cursor.y >= 1);
    const cell = self.screen.getCellPtr(
        .active,
        self.screen.cursor.y - 1,
        self.cols - 1,
    );
    cell.attrs.wide_spacer_head = false;
}

/// Print the previous printed character a repeated amount of times.
pub fn printRepeat(self: *Terminal, count: usize) !void {
    // TODO: test
    if (self.previous_char) |c| {
        var i: usize = 0;
        while (i < count) : (i += 1) try self.print(c);
    }
}

/// Resets all margins and fills the whole screen with the character 'E'
///
/// Sets the cursor to the top left corner.
pub fn decaln(self: *Terminal) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // Reset margins, also sets cursor to top-left
    self.setScrollingRegion(0, 0);

    // Fill with Es, does not move cursor. We reset fg/bg so we can just
    // optimize here by doing row copies.
    const filled = self.screen.getRow(.{ .active = 0 });
    filled.fill(.{ .char = 'E' });

    var row: usize = 1;
    while (row < self.rows) : (row += 1) {
        try self.screen.getRow(.{ .active = row }).copyRow(filled);
    }
}

/// Move the cursor to the next line in the scrolling region, possibly scrolling.
///
/// If the cursor is outside of the scrolling region: move the cursor one line
/// down if it is not on the bottom-most line of the screen.
///
/// If the cursor is inside the scrolling region:
///   If the cursor is on the bottom-most line of the scrolling region:
///     invoke scroll up with amount=1
///   If the cursor is not on the bottom-most line of the scrolling region:
///     move the cursor one line down
///
/// This unsets the pending wrap state without wrapping.
pub fn index(self: *Terminal) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // Unset pending wrap state
    self.screen.cursor.pending_wrap = false;

    // Outside of the scroll region we move the cursor one line down.
    if (self.screen.cursor.y < self.scrolling_region.top or
        self.screen.cursor.y > self.scrolling_region.bottom)
    {
        self.screen.cursor.y = @min(self.screen.cursor.y + 1, self.rows - 1);
        return;
    }

    // If the cursor is inside the scrolling region and on the bottom-most
    // line, then we scroll up. If our scrolling region is the full screen
    // we create scrollback.
    if (self.screen.cursor.y == self.scrolling_region.bottom and
        self.screen.cursor.x >= self.scrolling_region.left and
        self.screen.cursor.x <= self.scrolling_region.right)
    {
        // If our scrolling region is the full screen, we create scrollback.
        // Otherwise, we simply scroll the region.
        if (self.scrolling_region.top == 0 and
            self.scrolling_region.bottom == self.rows - 1 and
            self.scrolling_region.left == 0 and
            self.scrolling_region.right == self.cols - 1)
        {
            try self.screen.scroll(.{ .screen = 1 });
        } else {
            self.screen.scrollRegionUp(
                .{ .active = self.scrolling_region.top },
                .{ .active = self.scrolling_region.bottom },
                1,
            );
        }

        return;
    }

    // Increase cursor by 1, maximum to bottom of scroll region
    self.screen.cursor.y = @min(self.screen.cursor.y + 1, self.scrolling_region.bottom);
}

/// Move the cursor to the previous line in the scrolling region, possibly
/// scrolling.
///
/// If the cursor is outside of the scrolling region, move the cursor one
/// line up if it is not on the top-most line of the screen.
///
/// If the cursor is inside the scrolling region:
///
///   * If the cursor is on the top-most line of the scrolling region:
///     invoke scroll down with amount=1
///   * If the cursor is not on the top-most line of the scrolling region:
///     move the cursor one line up
pub fn reverseIndex(self: *Terminal) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // If the cursor is on the top-most line of the scroll region or
    // its on the top of the screen we scroll down.
    if (self.screen.cursor.y == self.scrolling_region.top or
        self.screen.cursor.y == 0)
    {
        try self.scrollDown(1);
    } else {
        self.screen.cursor.y -|= 1;
    }
}

// Set Cursor Position. Move cursor to the position indicated
// by row and column (1-indexed). If column is 0, it is adjusted to 1.
// If column is greater than the right-most column it is adjusted to
// the right-most column. If row is 0, it is adjusted to 1. If row is
// greater than the bottom-most row it is adjusted to the bottom-most
// row.
pub fn setCursorPos(self: *Terminal, row_req: usize, col_req: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    // If cursor origin mode is set the cursor row will be moved relative to
    // the top margin row and adjusted to be above or at bottom-most row in
    // the current scroll region.
    //
    // If origin mode is set and left and right margin mode is set the cursor
    // will be moved relative to the left margin column and adjusted to be on
    // or left of the right margin column.
    const params: struct {
        x_offset: usize = 0,
        y_offset: usize = 0,
        x_max: usize,
        y_max: usize,
    } = if (self.modes.get(.origin)) .{
        .x_offset = self.scrolling_region.left,
        .y_offset = self.scrolling_region.top,
        .x_max = self.scrolling_region.right + 1, // We need this 1-indexed
        .y_max = self.scrolling_region.bottom + 1, // We need this 1-indexed
    } else .{
        .x_max = self.cols,
        .y_max = self.rows,
    };

    const row = if (row_req == 0) 1 else row_req;
    const col = if (col_req == 0) 1 else col_req;
    self.screen.cursor.x = @min(params.x_max, col + params.x_offset) -| 1;
    self.screen.cursor.y = @min(params.y_max, row + params.y_offset) -| 1;
    // log.info("set cursor position: col={} row={}", .{ self.screen.cursor.x, self.screen.cursor.y });

    // Unset pending wrap state
    self.screen.cursor.pending_wrap = false;
}

/// Erase the display.
pub fn eraseDisplay(
    self: *Terminal,
    alloc: Allocator,
    mode: csi.EraseDisplay,
    protected_req: bool,
) void {
    const tracy = trace(@src());
    defer tracy.end();

    // Erasing clears all attributes / colors _except_ the background
    const pen: Screen.Cell = if (!self.screen.cursor.pen.attrs.has_bg) .{} else .{
        .bg = self.screen.cursor.pen.bg,
        .attrs = .{ .has_bg = true },
    };

    // We respect protected attributes if explicitly requested (probably
    // a DECSEL sequence) or if our last protected mode was ISO even if its
    // not currently set.
    const protected = self.screen.protected_mode == .iso or protected_req;

    switch (mode) {
        .complete => {
            var it = self.screen.rowIterator(.active);
            while (it.next()) |row| {
                row.setWrapped(false);
                row.setDirty(true);

                if (!protected) {
                    row.clear(pen);
                    continue;
                }

                // Protected mode erase
                for (0..row.lenCells()) |x| {
                    const cell = row.getCellPtr(x);
                    if (cell.attrs.protected) continue;
                    cell.* = pen;
                }
            }

            // Unsets pending wrap state
            self.screen.cursor.pending_wrap = false;

            // Clear all Kitty graphics state for this screen
            self.screen.kitty_images.delete(alloc, self, .{ .all = true });
        },

        .below => {
            // All lines to the right (including the cursor)
            {
                self.eraseLine(.right, protected_req);
                const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
                row.setWrapped(false);
                row.setDirty(true);
            }

            // All lines below
            for ((self.screen.cursor.y + 1)..self.rows) |y| {
                const row = self.screen.getRow(.{ .active = y });
                row.setWrapped(false);
                row.setDirty(true);
                for (0..self.cols) |x| {
                    if (row.header().flags.grapheme) row.clearGraphemes(x);
                    const cell = row.getCellPtr(x);
                    if (protected and cell.attrs.protected) continue;
                    cell.* = pen;
                    cell.char = 0;
                }
            }

            // Unsets pending wrap state
            self.screen.cursor.pending_wrap = false;
        },

        .above => {
            // Erase to the left (including the cursor)
            self.eraseLine(.left, protected_req);

            // All lines above
            var y: usize = 0;
            while (y < self.screen.cursor.y) : (y += 1) {
                var x: usize = 0;
                while (x < self.cols) : (x += 1) {
                    const cell = self.screen.getCellPtr(.active, y, x);
                    if (protected and cell.attrs.protected) continue;
                    cell.* = pen;
                    cell.char = 0;
                }
            }

            // Unsets pending wrap state
            self.screen.cursor.pending_wrap = false;
        },

        .scrollback => self.screen.clear(.history) catch |err| {
            // This isn't a huge issue, so just log it.
            log.err("failed to clear scrollback: {}", .{err});
        },
    }
}

/// Erase the line.
pub fn eraseLine(
    self: *Terminal,
    mode: csi.EraseLine,
    protected_req: bool,
) void {
    const tracy = trace(@src());
    defer tracy.end();

    // We always fill with the background
    const pen: Screen.Cell = if (!self.screen.cursor.pen.attrs.has_bg) .{} else .{
        .bg = self.screen.cursor.pen.bg,
        .attrs = .{ .has_bg = true },
    };

    // Get our start/end positions depending on mode.
    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
    const start, const end = switch (mode) {
        .right => right: {
            var x = self.screen.cursor.x;

            // If our X is a wide spacer tail then we need to erase the
            // previous cell too so we don't split a multi-cell character.
            if (x > 0) {
                const cell = row.getCellPtr(x);
                if (cell.attrs.wide_spacer_tail) x -= 1;
            }

            break :right .{ x, row.lenCells() };
        },

        .left => left: {
            var x = self.screen.cursor.x;

            // If our x is a wide char we need to delete the tail too.
            const cell = row.getCellPtr(x);
            if (cell.attrs.wide) {
                if (row.getCellPtr(x + 1).attrs.wide_spacer_tail) {
                    x += 1;
                }
            }

            break :left .{ 0, x + 1 };
        },

        .complete => .{ 0, row.lenCells() },

        else => {
            log.err("unimplemented erase line mode: {}", .{mode});
            return;
        },
    };

    // All modes will clear the pending wrap state and we know we have
    // a valid mode at this point.
    self.screen.cursor.pending_wrap = false;

    // We respect protected attributes if explicitly requested (probably
    // a DECSEL sequence) or if our last protected mode was ISO even if its
    // not currently set.
    const protected = self.screen.protected_mode == .iso or protected_req;

    // If we're not respecting protected attributes, we can use a fast-path
    // to fill the entire line.
    if (!protected) {
        row.fillSlice(self.screen.cursor.pen, start, end);
        return;
    }

    for (start..end) |x| {
        const cell = row.getCellPtr(x);
        if (cell.attrs.protected) continue;
        cell.* = pen;
    }
}

/// Removes amount characters from the current cursor position to the right.
/// The remaining characters are shifted to the left and space from the right
/// margin is filled with spaces.
///
/// If amount is greater than the remaining number of characters in the
/// scrolling region, it is adjusted down.
///
/// Does not change the cursor position.
pub fn deleteChars(self: *Terminal, count: usize) !void {
    const tracy = trace(@src());
    defer tracy.end();

    if (count == 0) return;

    // This resets the pending wrap state
    self.screen.cursor.pending_wrap = false;

    // We go from our cursor right to the end and either copy the cell
    // "count" away or clear it.
    const line = self.screen.getRow(.{ .active = self.screen.cursor.y });
    for (self.screen.cursor.x..self.cols) |x| {
        const copy_x = x + count;
        if (copy_x >= self.cols) {
            line.getCellPtr(x).* = .{};
            continue;
        }

        const copy_cell = line.getCellPtr(copy_x);
        line.getCellPtr(x).* = copy_cell.*;
        copy_cell.char = 0;
    }
}

pub fn eraseChars(self: *Terminal, count: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    // This resets the pending wrap state
    self.screen.cursor.pending_wrap = false;

    // Our last index is at most the end of the number of chars we have
    // in the current line.
    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
    const end = end: {
        var end = @min(self.cols, self.screen.cursor.x + count);

        // If our last cell is a wide char then we need to also clear the
        // cell beyond it since we can't just split a wide char.
        if (end != self.cols) {
            const last = row.getCellPtr(end - 1);
            if (last.attrs.wide) end += 1;
        }

        break :end end;
    };

    const pen: Screen.Cell = .{
        .bg = self.screen.cursor.pen.bg,
        .attrs = .{ .has_bg = self.screen.cursor.pen.attrs.has_bg },
    };

    // If we never had a protection mode, then we can assume no cells
    // are protected and go with the fast path. If the last protection
    // mode was not ISO we also always ignore protection attributes.
    if (self.screen.protected_mode != .iso) {
        row.fillSlice(pen, self.screen.cursor.x, end);
    }

    // We had a protection mode at some point. We must go through each
    // cell and check its protection attribute.
    for (self.screen.cursor.x..end) |x| {
        const cell = row.getCellPtr(x);
        if (cell.attrs.protected) continue;
        cell.* = pen;
    }
}

/// Move the cursor to the left amount cells. If amount is 0, adjust it to 1.
pub fn cursorLeft(self: *Terminal, count_req: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    // Wrapping behavior depends on various terminal modes
    const WrapMode = enum { none, reverse, reverse_extended };
    const wrap_mode: WrapMode = wrap_mode: {
        if (!self.modes.get(.wraparound)) break :wrap_mode .none;
        if (self.modes.get(.reverse_wrap_extended)) break :wrap_mode .reverse_extended;
        if (self.modes.get(.reverse_wrap)) break :wrap_mode .reverse;
        break :wrap_mode .none;
    };

    // If we have a pending wrap state on, we reset it and reduce our count.
    var count: usize = @max(count_req, 1);
    if (self.screen.cursor.pending_wrap) {
        self.screen.cursor.pending_wrap = false;
        count -= 1;
    }

    // If we are in no wrap mode, then we move the cursor left and exit
    // since this is the fastest and most typical path.
    if (wrap_mode == .none) {
        self.screen.cursor.x -|= count;
        return;
    }

    // The margins we can move to.
    // TODO: if cursor is left of the left margin, assume left margin to be 0.
    // verified with xterm. don't forget when left margins are implemented!
    const left_margin = 0;
    const right_margin = self.cols - 1;
    const top = self.scrolling_region.top;
    const bottom = self.scrolling_region.bottom;

    while (true) {
        // We can move at most to the left margin.
        const max = self.screen.cursor.x - left_margin;

        // We want to move at most the number of columns we have left
        // or our remaining count. Do the move.
        const amount = @min(max, count);
        count -= amount;
        self.screen.cursor.x -= amount;

        // If we have no more to move, then we're done.
        if (count == 0) break;

        // If we are at the top, then we are done.
        if (self.screen.cursor.y == top) {
            if (wrap_mode != .reverse_extended) break;

            self.screen.cursor.y = bottom;
            self.screen.cursor.x = right_margin;
            count -= 1;
            continue;
        }

        // If our previous line is not wrapped then we are done.
        const row = self.screen.getRow(.{ .active = self.screen.cursor.y - 1 });
        if (wrap_mode != .reverse_extended and !row.isWrapped()) break;
        self.screen.cursor.y -= 1;
        self.screen.cursor.x = right_margin;
        count -= 1;
    }
}

/// Move the cursor right amount columns. If amount is greater than the
/// maximum move distance then it is internally adjusted to the maximum.
/// This sequence will not scroll the screen or scroll region. If amount is
/// 0, adjust it to 1.
pub fn cursorRight(self: *Terminal, count_req: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    // Always resets pending wrap
    self.screen.cursor.pending_wrap = false;

    // The max the cursor can move to depends where the cursor currently is
    const max = if (self.screen.cursor.x <= self.scrolling_region.right)
        self.scrolling_region.right
    else
        self.cols - 1;

    const count = @max(count_req, 1);
    self.screen.cursor.x = @min(max, self.screen.cursor.x +| count);
}

/// Move the cursor down amount lines. If amount is greater than the maximum
/// move distance then it is internally adjusted to the maximum. This sequence
/// will not scroll the screen or scroll region. If amount is 0, adjust it to 1.
pub fn cursorDown(self: *Terminal, count_req: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    // Always resets pending wrap
    self.screen.cursor.pending_wrap = false;

    // The max the cursor can move to depends where the cursor currently is
    const max = if (self.screen.cursor.y <= self.scrolling_region.bottom)
        self.scrolling_region.bottom
    else
        self.rows - 1;

    const count = @max(count_req, 1);
    self.screen.cursor.y = @min(max, self.screen.cursor.y +| count);
}

/// Move the cursor up amount lines. If amount is greater than the maximum
/// move distance then it is internally adjusted to the maximum. If amount is
/// 0, adjust it to 1.
pub fn cursorUp(self: *Terminal, count_req: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    // Always resets pending wrap
    self.screen.cursor.pending_wrap = false;

    // The min the cursor can move to depends where the cursor currently is
    const min = if (self.screen.cursor.y >= self.scrolling_region.top)
        self.scrolling_region.top
    else
        0;

    const count = @max(count_req, 1);
    self.screen.cursor.y = @max(min, self.screen.cursor.y -| count);
}

/// Backspace moves the cursor back a column (but not less than 0).
pub fn backspace(self: *Terminal) void {
    const tracy = trace(@src());
    defer tracy.end();

    self.cursorLeft(1);
}

/// Horizontal tab moves the cursor to the next tabstop, clearing
/// the screen to the left the tabstop.
pub fn horizontalTab(self: *Terminal) !void {
    const tracy = trace(@src());
    defer tracy.end();

    while (self.screen.cursor.x < self.scrolling_region.right) {
        // Move the cursor right
        self.screen.cursor.x += 1;

        // If the last cursor position was a tabstop we return. We do
        // "last cursor position" because we want a space to be written
        // at the tabstop unless we're at the end (the while condition).
        if (self.tabstops.get(self.screen.cursor.x)) return;
    }
}

// Same as horizontalTab but moves to the previous tabstop instead of the next.
pub fn horizontalTabBack(self: *Terminal) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // With origin mode enabled, our leftmost limit is the left margin.
    const left_limit = if (self.modes.get(.origin)) self.scrolling_region.left else 0;

    while (true) {
        // If we're already at the edge of the screen, then we're done.
        if (self.screen.cursor.x == left_limit) return;

        // Move the cursor left
        self.screen.cursor.x -= 1;
        if (self.tabstops.get(self.screen.cursor.x)) return;
    }
}

/// Clear tab stops.
/// TODO: test
pub fn tabClear(self: *Terminal, cmd: csi.TabClear) void {
    switch (cmd) {
        .current => self.tabstops.unset(self.screen.cursor.x),
        .all => self.tabstops.reset(0),
        else => log.warn("invalid or unknown tab clear setting: {}", .{cmd}),
    }
}

/// Set a tab stop on the current cursor.
/// TODO: test
pub fn tabSet(self: *Terminal) void {
    self.tabstops.set(self.screen.cursor.x);
}

/// Carriage return moves the cursor to the first column.
pub fn carriageReturn(self: *Terminal) void {
    const tracy = trace(@src());
    defer tracy.end();

    // Always reset pending wrap state
    self.screen.cursor.pending_wrap = false;

    // In origin mode we always move to the left margin
    self.screen.cursor.x = if (self.modes.get(.origin))
        self.scrolling_region.left
    else if (self.screen.cursor.x >= self.scrolling_region.left)
        self.scrolling_region.left
    else
        0;
}

/// Linefeed moves the cursor to the next line.
pub fn linefeed(self: *Terminal) !void {
    const tracy = trace(@src());
    defer tracy.end();

    try self.index();
}

/// Inserts spaces at current cursor position moving existing cell contents
/// to the right. The contents of the count right-most columns in the scroll
/// region are lost. The cursor position is not changed.
///
/// This unsets the pending wrap state without wrapping.
///
/// The inserted cells are colored according to the current SGR state.
pub fn insertBlanks(self: *Terminal, count: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    // Unset pending wrap state without wrapping
    self.screen.cursor.pending_wrap = false;

    // If our cursor is outside the margins then do nothing. We DO reset
    // wrap state still so this must remain below the above logic.
    if (self.screen.cursor.x < self.scrolling_region.left or
        self.screen.cursor.x > self.scrolling_region.right) return;

    // The limit we can shift to is our right margin. We add 1 since the
    // math around this is 1-indexed.
    const right_limit = self.scrolling_region.right + 1;

    // If our count is larger than the remaining amount, we just erase right.
    // We only do this if we can erase the entire line (no right margin).
    if (right_limit == self.cols and
        count > right_limit - self.screen.cursor.x)
    {
        self.eraseLine(.right, false);
        return;
    }

    // Get the current row
    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });

    // Determine our indexes.
    const start = self.screen.cursor.x;
    const pivot = self.screen.cursor.x + count;

    // This is the number of spaces we have left to shift existing data.
    // If count is bigger than the available space left after the cursor,
    // we may have no space at all for copying.
    const copyable = right_limit - pivot;
    if (copyable > 0) {
        // This is the index of the final copyable value that we need to copy.
        const copyable_end = start + copyable - 1;

        // Shift count cells. We have to do this backwards since we're not
        // allocated new space, otherwise we'll copy duplicates.
        var i: usize = 0;
        while (i < copyable) : (i += 1) {
            const to = right_limit - 1 - i;
            const from = copyable_end - i;
            const src = row.getCell(from);
            const dst = row.getCellPtr(to);
            dst.* = src;
        }
    }

    // Insert blanks. The blanks preserve the background color.
    row.fillSlice(.{
        .bg = self.screen.cursor.pen.bg,
        .attrs = .{ .has_bg = self.screen.cursor.pen.attrs.has_bg },
    }, start, pivot);
}

/// Insert amount lines at the current cursor row. The contents of the line
/// at the current cursor row and below (to the bottom-most line in the
/// scrolling region) are shifted down by amount lines. The contents of the
/// amount bottom-most lines in the scroll region are lost.
///
/// This unsets the pending wrap state without wrapping. If the current cursor
/// position is outside of the current scroll region it does nothing.
///
/// If amount is greater than the remaining number of lines in the scrolling
/// region it is adjusted down (still allowing for scrolling out every remaining
/// line in the scrolling region)
///
/// In left and right margin mode the margins are respected; lines are only
/// scrolled in the scroll region.
///
/// All cleared space is colored according to the current SGR state.
///
/// Moves the cursor to the left margin.
pub fn insertLines(self: *Terminal, count: usize) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // Rare, but happens
    if (count == 0) return;

    // If the cursor is outside the scroll region we do nothing.
    if (self.screen.cursor.y < self.scrolling_region.top or
        self.screen.cursor.y > self.scrolling_region.bottom or
        self.screen.cursor.x < self.scrolling_region.left or
        self.screen.cursor.x > self.scrolling_region.right) return;

    // Move the cursor to the left margin
    self.screen.cursor.x = self.scrolling_region.left;
    self.screen.cursor.pending_wrap = false;

    // Remaining rows from our cursor
    const rem = self.scrolling_region.bottom - self.screen.cursor.y + 1;

    // If count is greater than the amount of rows, adjust down.
    const adjusted_count = @min(count, rem);

    // The the top `scroll_amount` lines need to move to the bottom
    // scroll area. We may have nothing to scroll if we're clearing.
    const scroll_amount = rem - adjusted_count;
    var y: usize = self.scrolling_region.bottom;
    const top = y - scroll_amount;

    // Ensure we have the lines populated to the end
    while (y > top) : (y -= 1) {
        const src = self.screen.getRow(.{ .active = y - adjusted_count });
        const dst = self.screen.getRow(.{ .active = y });
        try dst.copyRow(src);
    }

    // Insert count blank lines
    y = self.screen.cursor.y;
    while (y < self.screen.cursor.y + adjusted_count) : (y += 1) {
        const row = self.screen.getRow(.{ .active = y });
        row.fillSlice(.{
            .bg = self.screen.cursor.pen.bg,
            .attrs = .{ .has_bg = self.screen.cursor.pen.attrs.has_bg },
        }, self.scrolling_region.left, self.scrolling_region.right + 1);
    }
}

/// Removes amount lines from the current cursor row down. The remaining lines
/// to the bottom margin are shifted up and space from the bottom margin up is
/// filled with empty lines.
///
/// If the current cursor position is outside of the current scroll region it
/// does nothing. If amount is greater than the remaining number of lines in the
/// scrolling region it is adjusted down.
///
/// In left and right margin mode the margins are respected; lines are only
/// scrolled in the scroll region.
///
/// If the cell movement splits a multi cell character that character cleared,
/// by replacing it by spaces, keeping its current attributes. All other
/// cleared space is colored according to the current SGR state.
///
/// Moves the cursor to the left margin.
pub fn deleteLines(self: *Terminal, count: usize) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // If our cursor is outside of the scroll region, do nothing.
    if (self.screen.cursor.y < self.scrolling_region.top or
        self.screen.cursor.y > self.scrolling_region.bottom)
    {
        return;
    }

    // Move the cursor to the left margin
    self.screen.cursor.x = 0;
    self.screen.cursor.pending_wrap = false;

    // Perform the scroll
    self.screen.scrollRegionUp(
        .{ .active = self.screen.cursor.y },
        .{ .active = self.scrolling_region.bottom },
        @min(count, self.scrolling_region.bottom - self.screen.cursor.y),
    );
}

/// Scroll the text down by one row.
/// TODO: test
pub fn scrollDown(self: *Terminal, count: usize) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // Preserve the cursor
    const cursor = self.screen.cursor;
    defer self.screen.cursor = cursor;

    // Move to the top of the scroll region
    self.screen.cursor.y = self.scrolling_region.top;
    try self.insertLines(count);
}

/// Removes amount lines from the top of the scroll region. The remaining lines
/// to the bottom margin are shifted up and space from the bottom margin up
/// is filled with empty lines.
///
/// The new lines are created according to the current SGR state.
///
/// Does not change the (absolute) cursor position.
// TODO: test
pub fn scrollUp(self: *Terminal, count: usize) !void {
    self.screen.scrollRegionUp(
        .{ .active = self.scrolling_region.top },
        .{ .active = self.scrolling_region.bottom },
        count,
    );
}

/// Options for scrolling the viewport of the terminal grid.
pub const ScrollViewport = union(enum) {
    /// Scroll to the top of the scrollback
    top: void,

    /// Scroll to the bottom, i.e. the top of the active area
    bottom: void,

    /// Scroll by some delta amount, up is negative.
    delta: isize,
};

/// Scroll the viewport of the terminal grid.
pub fn scrollViewport(self: *Terminal, behavior: ScrollViewport) !void {
    const tracy = trace(@src());
    defer tracy.end();

    try self.screen.scroll(switch (behavior) {
        .top => .{ .top = {} },
        .bottom => .{ .bottom = {} },
        .delta => |delta| .{ .viewport = delta },
    });
}

/// Set Top and Bottom Margins If bottom is not specified, 0 or bigger than
/// the number of the bottom-most row, it is adjusted to the number of the
/// bottom most row.
///
/// If top < bottom set the top and bottom row of the scroll region according
/// to top and bottom and move the cursor to the top-left cell of the display
/// (when in cursor origin mode is set to the top-left cell of the scroll region).
///
/// Otherwise: Set the top and bottom row of the scroll region to the top-most
/// and bottom-most line of the screen.
///
/// Top and bottom are 1-indexed.
pub fn setScrollingRegion(self: *Terminal, top: usize, bottom: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    var t = if (top == 0) 1 else top;
    var b = @min(bottom, self.rows);
    if (t >= b) {
        t = 1;
        b = self.rows;
    }

    self.scrolling_region.top = t - 1;
    self.scrolling_region.bottom = b - 1;
    self.setCursorPos(1, 1);
}

/// Mark the current semantic prompt information. Current escape sequences
/// (OSC 133) only allow setting this for wherever the current active cursor
/// is located.
pub fn markSemanticPrompt(self: *Terminal, p: SemanticPrompt) void {
    //log.warn("semantic_prompt y={} p={}", .{ self.screen.cursor.y, p });
    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
    row.setSemanticPrompt(switch (p) {
        .prompt => .prompt,
        .prompt_continuation => .prompt_continuation,
        .input => .input,
        .command => .command,
    });
}

/// Returns true if the cursor is currently at a prompt. Another way to look
/// at this is it returns false if the shell is currently outputting something.
/// This requires shell integration (semantic prompt integration).
///
/// If the shell integration doesn't exist, this will always return false.
pub fn cursorIsAtPrompt(self: *Terminal) bool {
    // If we're on the secondary screen, we're never at a prompt.
    if (self.active_screen == .alternate) return false;

    var y: usize = 0;
    while (y <= self.screen.cursor.y) : (y += 1) {
        // We want to go bottom up
        const bottom_y = self.screen.cursor.y - y;
        const row = self.screen.getRow(.{ .active = bottom_y });
        switch (row.getSemanticPrompt()) {
            // If we're at a prompt or input area, then we are at a prompt.
            .prompt,
            .prompt_continuation,
            .input,
            => return true,

            // If we have command output, then we're most certainly not
            // at a prompt.
            .command => return false,

            // If we don't know, we keep searching.
            .unknown => {},
        }
    }

    return false;
}

/// Set the pwd for the terminal.
pub fn setPwd(self: *Terminal, pwd: []const u8) !void {
    self.pwd.clearRetainingCapacity();
    try self.pwd.appendSlice(pwd);
}

/// Returns the pwd for the terminal, if any. The memory is owned by the
/// Terminal and is not copied. It is safe until a reset or setPwd.
pub fn getPwd(self: *const Terminal) ?[]const u8 {
    if (self.pwd.items.len == 0) return null;
    return self.pwd.items;
}

/// Execute a kitty graphics command. The buf is used to populate with
/// the response that should be sent as an APC sequence. The response will
/// be a full, valid APC sequence.
///
/// If an error occurs, the caller should response to the pty that a
/// an error occurred otherwise the behavior of the graphics protocol is
/// undefined.
pub fn kittyGraphics(
    self: *Terminal,
    alloc: Allocator,
    cmd: *kitty.graphics.Command,
) ?kitty.graphics.Response {
    return kitty.graphics.execute(alloc, self, cmd);
}

/// Set the character protection mode for the terminal.
pub fn setProtectedMode(self: *Terminal, mode: ansi.ProtectedMode) void {
    switch (mode) {
        .off => {
            self.screen.cursor.pen.attrs.protected = false;

            // screen.protected_mode is NEVER reset to ".off" because
            // logic such as eraseChars depends on knowing what the
            // _most recent_ mode was.
        },

        .iso => {
            self.screen.cursor.pen.attrs.protected = true;
            self.screen.protected_mode = .iso;
        },

        .dec => {
            self.screen.cursor.pen.attrs.protected = true;
            self.screen.protected_mode = .dec;
        },
    }
}

/// Full reset
pub fn fullReset(self: *Terminal, alloc: Allocator) void {
    self.primaryScreen(alloc, .{ .clear_on_exit = true, .cursor_save = true });
    self.screen.charset = .{};
    self.modes = .{};
    self.flags = .{};
    self.tabstops.reset(0);
    self.screen.cursor = .{};
    self.screen.saved_cursor = .{};
    self.screen.selection = null;
    self.screen.kitty_keyboard = .{};
    self.screen.protected_mode = .off;
    self.scrolling_region = .{
        .top = 0,
        .bottom = self.rows - 1,
        .left = 0,
        .right = self.cols - 1,
    };
    self.previous_char = null;
    self.eraseDisplay(alloc, .scrollback, false);
    self.eraseDisplay(alloc, .complete, false);
    self.pwd.clearRetainingCapacity();
}

test "Terminal: fullReset with a non-empty pen" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    t.screen.cursor.pen.bg = .{ .r = 0xFF, .g = 0x00, .b = 0x7F };
    t.screen.cursor.pen.fg = .{ .r = 0xFF, .g = 0x00, .b = 0x7F };
    t.fullReset(testing.allocator);

    const cell = t.screen.getCell(.active, t.screen.cursor.y, t.screen.cursor.x);
    try testing.expect(cell.bg.eql(.{}));
    try testing.expect(cell.fg.eql(.{}));
}

test "Terminal: input with no control characters" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screen.cursor.x);
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }
}

test "Terminal: zero-width character at start" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // This used to crash the terminal. This is not allowed so we should
    // just ignore it.
    try t.print(0x200D);

    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
}

test "Terminal: print over wide char at 0,0" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    try t.print(0x1F600); // Smiley face
    t.setCursorPos(0, 0);
    try t.print('A'); // Smiley face

    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screen.cursor.x);
}

test "Terminal: print multicodepoint grapheme, disabled mode 2027" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // https://github.com/mitchellh/ghostty/issues/289
    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    // We should have 6 cells taken up
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 6), t.screen.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(0);
        try testing.expectEqual(@as(u32, 0x1F468), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expectEqual(@as(usize, 2), row.codepointLen(0));
    }
    {
        const cell = row.getCell(1);
        try testing.expectEqual(@as(u32, ' '), cell.char);
        try testing.expect(cell.attrs.wide_spacer_tail);
        try testing.expectEqual(@as(usize, 1), row.codepointLen(1));
    }
    {
        const cell = row.getCell(2);
        try testing.expectEqual(@as(u32, 0x1F469), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expectEqual(@as(usize, 2), row.codepointLen(2));
    }
    {
        const cell = row.getCell(3);
        try testing.expectEqual(@as(u32, ' '), cell.char);
        try testing.expect(cell.attrs.wide_spacer_tail);
    }
    {
        const cell = row.getCell(4);
        try testing.expectEqual(@as(u32, 0x1F467), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expectEqual(@as(usize, 1), row.codepointLen(4));
    }
    {
        const cell = row.getCell(5);
        try testing.expectEqual(@as(u32, ' '), cell.char);
        try testing.expect(cell.attrs.wide_spacer_tail);
    }
}

test "Terminal: print multicodepoint grapheme, mode 2027" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // https://github.com/mitchellh/ghostty/issues/289
    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screen.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(0);
        try testing.expectEqual(@as(u32, 0x1F468), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expectEqual(@as(usize, 5), row.codepointLen(0));
    }
    {
        const cell = row.getCell(1);
        try testing.expectEqual(@as(u32, ' '), cell.char);
        try testing.expect(cell.attrs.wide_spacer_tail);
        try testing.expectEqual(@as(usize, 1), row.codepointLen(1));
    }
}

test "Terminal: soft wrap" {
    var t = try init(testing.allocator, 3, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 1), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screen.cursor.x);
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hel\nlo", str);
    }
}

test "Terminal: print writes to bottom if scrolled" {
    var t = try init(testing.allocator, 5, 2);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    t.setCursorPos(0, 0);

    // Make newlines so we create scrollback
    // 3 pushes hello off the screen
    try t.index();
    try t.index();
    try t.index();
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Scroll to the top
    try t.scrollViewport(.{ .top = {} });
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }

    // Type
    try t.print('A');
    try t.scrollViewport(.{ .bottom = {} });
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA", str);
    }
}

test "Terminal: print charset" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // G1 should have no effect
    t.configureCharset(.G1, .dec_special);
    t.configureCharset(.G2, .dec_special);
    t.configureCharset(.G3, .dec_special);

    // Basic grid writing
    try t.print('`');
    t.configureCharset(.G0, .utf8);
    try t.print('`');
    t.configureCharset(.G0, .ascii);
    try t.print('`');
    t.configureCharset(.G0, .dec_special);
    try t.print('`');
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("```◆", str);
    }
}

test "Terminal: print charset outside of ASCII" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // G1 should have no effect
    t.configureCharset(.G1, .dec_special);
    t.configureCharset(.G2, .dec_special);
    t.configureCharset(.G3, .dec_special);

    // Basic grid writing
    t.configureCharset(.G0, .dec_special);
    try t.print('`');
    try t.print(0x1F600);
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("◆ ", str);
    }
}

test "Terminal: print invoke charset" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    t.configureCharset(.G1, .dec_special);

    // Basic grid writing
    try t.print('`');
    t.invokeCharset(.GL, .G1, false);
    try t.print('`');
    try t.print('`');
    t.invokeCharset(.GL, .G0, false);
    try t.print('`');
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("`◆◆`", str);
    }
}

test "Terminal: print invoke charset single" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    t.configureCharset(.G1, .dec_special);

    // Basic grid writing
    try t.print('`');
    t.invokeCharset(.GL, .G1, true);
    try t.print('`');
    try t.print('`');
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("`◆`", str);
    }
}

test "Terminal: linefeed and carriage return" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("world") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 1), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screen.cursor.x);
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello\nworld", str);
    }
}

test "Terminal: linefeed unsets pending wrap" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap == true);
    try t.linefeed();
    try testing.expect(t.screen.cursor.pending_wrap == false);
}

test "Terminal: carriage return unsets pending wrap" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap == true);
    t.carriageReturn();
    try testing.expect(t.screen.cursor.pending_wrap == false);
}

test "Terminal: carriage return origin mode moves to left margin" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    t.modes.set(.origin, true);
    t.screen.cursor.x = 0;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 2), t.screen.cursor.x);
}

test "Terminal: carriage return left of left margin moves to zero" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    t.screen.cursor.x = 1;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
}

test "Terminal: carriage return right of left margin moves to left margin" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    t.screen.cursor.x = 3;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 2), t.screen.cursor.x);
}

test "Terminal: backspace" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // BS
    for ("hello") |c| try t.print(c);
    t.backspace();
    try t.print('y');
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screen.cursor.x);
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("helly", str);
    }
}

test "Terminal: horizontal tabs" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    // HT
    try t.print('1');
    try t.horizontalTab();
    try testing.expectEqual(@as(usize, 8), t.screen.cursor.x);

    // HT
    try t.horizontalTab();
    try testing.expectEqual(@as(usize, 16), t.screen.cursor.x);

    // HT at the end
    try t.horizontalTab();
    try testing.expectEqual(@as(usize, 19), t.screen.cursor.x);
    try t.horizontalTab();
    try testing.expectEqual(@as(usize, 19), t.screen.cursor.x);
}

test "Terminal: horizontal tabs starting on tabstop" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    t.screen.cursor.x = 8;
    try t.print('X');
    t.screen.cursor.x = 8;
    try t.horizontalTab();
    try t.print('A');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("        X       A", str);
    }
}

test "Terminal: horizontal tabs with right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    t.scrolling_region.left = 2;
    t.scrolling_region.right = 5;
    t.screen.cursor.x = 0;
    try t.print('X');
    try t.horizontalTab();
    try t.print('A');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X    A", str);
    }
}

test "Terminal: horizontal tabs back" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    // Edge of screen
    t.screen.cursor.x = 19;

    // HT
    try t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 16), t.screen.cursor.x);

    // HT
    try t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 8), t.screen.cursor.x);

    // HT
    try t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
}

test "Terminal: horizontal tabs back starting on tabstop" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    t.screen.cursor.x = 8;
    try t.print('X');
    t.screen.cursor.x = 8;
    try t.horizontalTabBack();
    try t.print('A');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A       X", str);
    }
}

test "Terminal: horizontal tabs with left margin in origin mode" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    t.modes.set(.origin, true);
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 5;
    t.screen.cursor.x = 3;
    try t.print('X');
    try t.horizontalTabBack();
    try t.print('A');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  AX", str);
    }
}

test "Terminal: cursorPos resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.setCursorPos(1, 1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBCDE", str);
    }
}

test "Terminal: cursorPos off the screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setCursorPos(500, 500);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\n\n    X", str);
    }
}

test "Terminal: cursorPos relative to origin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.scrolling_region.top = 2;
    t.scrolling_region.bottom = 3;
    t.modes.set(.origin, true);
    t.setCursorPos(1, 1);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nX", str);
    }
}

test "Terminal: cursorPos relative to origin with left/right" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.scrolling_region.top = 2;
    t.scrolling_region.bottom = 3;
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.modes.set(.origin, true);
    t.setCursorPos(1, 1);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n  X", str);
    }
}

test "Terminal: cursorPos limits with full scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.scrolling_region.top = 2;
    t.scrolling_region.bottom = 3;
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.modes.set(.origin, true);
    t.setCursorPos(500, 500);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\n    X", str);
    }
}

test "Terminal: setCursorPos (original test)" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);

    // Setting it to 0 should keep it zero (1 based)
    t.setCursorPos(0, 0);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);

    // Should clamp to size
    t.setCursorPos(81, 81);
    try testing.expectEqual(@as(usize, 79), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screen.cursor.y);

    // Should reset pending wrap
    t.setCursorPos(0, 80);
    try t.print('c');
    try testing.expect(t.screen.cursor.pending_wrap);
    t.setCursorPos(0, 80);
    try testing.expect(!t.screen.cursor.pending_wrap);

    // Origin mode
    t.modes.set(.origin, true);

    // No change without a scroll region
    t.setCursorPos(81, 81);
    try testing.expectEqual(@as(usize, 79), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screen.cursor.y);

    // Set the scroll region
    t.setScrollingRegion(10, t.rows);
    t.setCursorPos(0, 0);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screen.cursor.y);

    t.setCursorPos(1, 1);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screen.cursor.y);

    t.setCursorPos(100, 0);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screen.cursor.y);

    t.setScrollingRegion(10, 11);
    t.setCursorPos(2, 0);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 10), t.screen.cursor.y);
}

test "Terminal: setScrollingRegion" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // Initial value
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, t.rows - 1), t.scrolling_region.bottom);

    // Move our cusor so we can verify we move it back
    t.setCursorPos(5, 5);
    t.setScrollingRegion(3, 7);

    // Cursor should move back to top-left
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);

    // Scroll region is set
    try testing.expectEqual(@as(usize, 2), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, 6), t.scrolling_region.bottom);

    // Scroll region invalid
    t.setScrollingRegion(7, 3);
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, t.rows - 1), t.scrolling_region.bottom);

    // Scroll region with zero top and bottom
    t.setScrollingRegion(0, 0);
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, t.rows - 1), t.scrolling_region.bottom);
}

test "Terminal: deleteLines" {
    const alloc = testing.allocator;
    var t = try init(alloc, 80, 80);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');

    t.cursorUp(2);
    try t.deleteLines(1);

    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    // We should be
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 2), t.screen.cursor.y);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nE\nD", str);
    }
}

test "Terminal: deleteLines with scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 80, 80);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');

    t.setScrollingRegion(1, 3);
    t.setCursorPos(1, 1);
    try t.deleteLines(1);

    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    // We should be
    // try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    // try testing.expectEqual(@as(usize, 2), t.screen.cursor.y);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\nC\n\nD", str);
    }
}

test "Terminal: deleteLines with scroll region, large count" {
    const alloc = testing.allocator;
    var t = try init(alloc, 80, 80);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');

    t.setScrollingRegion(1, 3);
    t.setCursorPos(1, 1);
    try t.deleteLines(5);

    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    // We should be
    // try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    // try testing.expectEqual(@as(usize, 2), t.screen.cursor.y);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\n\n\nD", str);
    }
}

test "Terminal: deleteLines with scroll region, cursor outside of region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 80, 80);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');

    t.setScrollingRegion(1, 3);
    t.setCursorPos(4, 1);
    try t.deleteLines(1);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nB\nC\nD", str);
    }
}

test "Terminal: deleteLines resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    try t.deleteLines(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('B');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B", str);
    }
}

test "Terminal: insertLines simple" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    try t.insertLines(1);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\nGHI", str);
    }
}

test "Terminal: insertLines outside of scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setScrollingRegion(3, 4);
    t.setCursorPos(2, 2);
    try t.insertLines(1);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: insertLines top/bottom scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("123");
    t.setScrollingRegion(1, 3);
    t.setCursorPos(2, 2);
    try t.insertLines(1);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\n123", str);
    }
}

// test "Terminal: insertLines left/right scroll region" {
//     const alloc = testing.allocator;
//     var t = try init(alloc, 10, 10);
//     defer t.deinit(alloc);
//
//     try t.printString("ABC123");
//     t.carriageReturn();
//     try t.linefeed();
//     try t.printString("DEF456");
//     t.carriageReturn();
//     try t.linefeed();
//     try t.printString("GHI789");
//     t.scrolling_region.left = 1;
//     t.scrolling_region.right = 3;
//     t.setCursorPos(2, 2);
//     try t.insertLines(1);
//
//     {
//         var str = try t.plainString(testing.allocator);
//         defer testing.allocator.free(str);
//         try testing.expectEqualStrings("ABC123\nD   56\nGEF489\n HI7", str);
//     }
// }

test "Terminal: insertLines" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    try t.print('E');

    // Move to row 2
    t.setCursorPos(2, 1);

    // Insert two lines
    try t.insertLines(2);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n\nB\nC", str);
    }
}

test "Terminal: insertLines zero" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    // This should do nothing
    t.setCursorPos(1, 1);
    try t.insertLines(0);
}

test "Terminal: insertLines with scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 6);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    try t.print('E');

    t.setScrollingRegion(1, 2);
    t.setCursorPos(1, 1);
    try t.insertLines(1);

    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\nA\nC\nD\nE", str);
    }
}

test "Terminal: insertLines more than remaining" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    try t.print('E');

    // Move to row 2
    t.setCursorPos(2, 1);

    // Insert a bunch of  lines
    try t.insertLines(20);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

test "Terminal: insertLines resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    try t.insertLines(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('B');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nABCDE", str);
    }
}

test "Terminal: reverseIndex" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    try t.reverseIndex();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    t.carriageReturn();
    try t.linefeed();

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nBD\nC", str);
    }
}

test "Terminal: reverseIndex from the top" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    t.carriageReturn();
    try t.linefeed();

    t.setCursorPos(1, 1);
    try t.reverseIndex();
    try t.print('D');

    t.carriageReturn();
    try t.linefeed();
    t.setCursorPos(1, 1);
    try t.reverseIndex();
    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\nD\nA\nB", str);
    }
}

test "Terminal: reverseIndex top of scrolling region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 10);
    defer t.deinit(alloc);

    // Initial value
    t.setCursorPos(2, 1);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();

    // Set our scroll region
    t.setScrollingRegion(2, 5);
    t.setCursorPos(2, 1);
    try t.reverseIndex();
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nX\nA\nB\nC", str);
    }
}

test "Terminal: index" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    try t.index();
    try t.print('A');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA", str);
    }
}

test "Terminal: index from the bottom" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    t.setCursorPos(5, 1);
    try t.print('A');
    t.cursorLeft(1); // undo moving right from 'A'
    try t.index();

    try t.print('B');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA\nB", str);
    }
}

test "Terminal: index outside of scrolling region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    t.setScrollingRegion(2, 5);
    try t.index();
    try testing.expectEqual(@as(usize, 1), t.screen.cursor.y);
}

test "Terminal: index from the bottom outside of scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    t.setScrollingRegion(1, 2);
    t.setCursorPos(5, 1);
    try t.print('A');
    try t.index();
    try t.print('B');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\n\nAB", str);
    }
}

test "Terminal: index no scroll region, top of screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.print('A');
    try t.index();
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n X", str);
    }
}

test "Terminal: index bottom of primary screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setCursorPos(5, 1);
    try t.print('A');
    try t.index();
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA\n X", str);
    }
}

test "Terminal: index inside scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setScrollingRegion(1, 3);
    try t.print('A');
    try t.index();
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n X", str);
    }
}

test "Terminal: index bottom of scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setScrollingRegion(1, 3);
    t.setCursorPos(4, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('A');
    try t.index();
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA\n X\nB", str);
    }
}

test "Terminal: index bottom of primary screen with scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setScrollingRegion(1, 3);
    t.setCursorPos(3, 1);
    try t.print('A');
    t.setCursorPos(5, 1);
    try t.index();
    try t.index();
    try t.index();
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nA\n\nX", str);
    }
}

test "Terminal: index outside left/right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    t.setScrollingRegion(1, 3);
    t.scrolling_region.left = 3;
    t.scrolling_region.right = 5;
    t.setCursorPos(3, 3);
    try t.print('A');
    t.setCursorPos(3, 1);
    try t.index();
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nX A", str);
    }
}

test "Terminal: index inside left/right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    t.setScrollingRegion(1, 3);
    t.scrolling_region.left = 3;
    t.scrolling_region.right = 5;
    t.setCursorPos(3, 3);
    try t.print('A');
    try t.index();
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  A\n   X", str);
    }
}

test "Terminal: DECALN" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 2);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    try t.decaln();

    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("EE\nEE", str);
    }
}

test "Terminal: insertBlanks" {
    // NOTE: this is not verified with conformance tests, so these
    // tests might actually be verifying wrong behavior.
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 2);
    defer t.deinit(alloc);

    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.screen.cursor.pen.attrs.bold = true;
    t.setCursorPos(1, 1);
    t.insertBlanks(2);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
        const cell = t.screen.getCell(.active, 0, 0);
        try testing.expect(!cell.attrs.bold);
    }
}

test "Terminal: insertBlanks pushes off end" {
    // NOTE: this is not verified with conformance tests, so these
    // tests might actually be verifying wrong behavior.
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 2);
    defer t.deinit(alloc);

    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);
    t.insertBlanks(2);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  A", str);
    }
}

test "Terminal: insertBlanks more than size" {
    // NOTE: this is not verified with conformance tests, so these
    // tests might actually be verifying wrong behavior.
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 2);
    defer t.deinit(alloc);

    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);
    t.insertBlanks(5);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: insertBlanks no scroll region, fits" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.insertBlanks(2);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
    }
}

test "Terminal: insertBlanks preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
    defer t.deinit(alloc);

    const pen: Screen.Cell = .{
        .bg = .{ .r = 0xFF, .g = 0x00, .b = 0x00 },
        .attrs = .{ .has_bg = true },
    };

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.screen.cursor.pen = pen;
    t.insertBlanks(2);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
        const cell = t.screen.getCell(.active, 0, 0);
        try testing.expectEqual(pen, cell);
    }
}

test "Terminal: insertBlanks shift off screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 10);
    defer t.deinit(alloc);

    for ("  ABC") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.insertBlanks(2);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X A", str);
    }
}

test "Terminal: insertBlanks inside left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
    defer t.deinit(alloc);

    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.setCursorPos(1, 3);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.insertBlanks(2);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X A", str);
    }
}

test "Terminal: insertBlanks outside left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
    defer t.deinit(alloc);

    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.setCursorPos(1, 3);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.insertBlanks(2);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X ABC", str);
    }
}

test "Terminal: insert mode with space" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 2);
    defer t.deinit(alloc);

    for ("hello") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.modes.set(.insert, true);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hXello", str);
    }
}

test "Terminal: insert mode doesn't wrap pushed characters" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 2);
    defer t.deinit(alloc);

    for ("hello") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.modes.set(.insert, true);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hXell", str);
    }
}

test "Terminal: insert mode does nothing at the end of the line" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 2);
    defer t.deinit(alloc);

    for ("hello") |c| try t.print(c);
    t.modes.set(.insert, true);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello\nX", str);
    }
}

test "Terminal: insert mode with wide characters" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 2);
    defer t.deinit(alloc);

    for ("hello") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.modes.set(.insert, true);
    try t.print('😀'); // 0x1F600

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("h😀el", str);
    }
}

test "Terminal: insert mode with wide characters at end" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 2);
    defer t.deinit(alloc);

    for ("well") |c| try t.print(c);
    t.modes.set(.insert, true);
    try t.print('😀'); // 0x1F600

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("well\n😀", str);
    }
}

test "Terminal: cursorIsAtPrompt" {
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 2);
    defer t.deinit(alloc);

    try testing.expect(!t.cursorIsAtPrompt());
    t.markSemanticPrompt(.prompt);
    try testing.expect(t.cursorIsAtPrompt());

    // Input is also a prompt
    t.markSemanticPrompt(.input);
    try testing.expect(t.cursorIsAtPrompt());

    // Newline -- we expect we're still at a prompt if we received
    // prompt stuff before.
    try t.linefeed();
    try testing.expect(t.cursorIsAtPrompt());

    // But once we say we're starting output, we're not a prompt
    t.markSemanticPrompt(.command);
    try testing.expect(!t.cursorIsAtPrompt());
    try t.linefeed();
    try testing.expect(!t.cursorIsAtPrompt());

    // Until we know we're at a prompt again
    try t.linefeed();
    t.markSemanticPrompt(.prompt);
    try testing.expect(t.cursorIsAtPrompt());
}

test "Terminal: cursorIsAtPrompt alternate screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 2);
    defer t.deinit(alloc);

    try testing.expect(!t.cursorIsAtPrompt());
    t.markSemanticPrompt(.prompt);
    try testing.expect(t.cursorIsAtPrompt());

    // Secondary screen is never a prompt
    t.alternateScreen(alloc, .{});
    try testing.expect(!t.cursorIsAtPrompt());
    t.markSemanticPrompt(.prompt);
    try testing.expect(!t.cursorIsAtPrompt());
}

test "Terminal: print wide char with 1-column width" {
    const alloc = testing.allocator;
    var t = try init(alloc, 1, 2);
    defer t.deinit(alloc);

    try t.print('😀'); // 0x1F600
}

test "Terminal: deleteChars" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    // the cells that shifted in should not have this attribute set
    t.screen.cursor.pen = .{ .attrs = .{ .bold = true } };

    try t.deleteChars(2);
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ADE", str);

        const cell = t.screen.getCell(.active, 0, 4);
        try testing.expect(!cell.attrs.bold);
    }
}

test "Terminal: deleteChars zero count" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    try t.deleteChars(0);
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE", str);
    }
}

test "Terminal: deleteChars more than half" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    try t.deleteChars(3);
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AE", str);
    }
}

test "Terminal: deleteChars more than line width" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    try t.deleteChars(10);
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

test "Terminal: deleteChars should shift left" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    try t.deleteChars(1);
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ACDE", str);
    }
}

test "Terminal: deleteChars resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    try t.deleteChars(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: eraseChars resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.eraseChars(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: eraseChars simple operation" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseChars(2);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X C", str);
    }
}

test "Terminal: eraseChars beyond screen edge" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("  ABC") |c| try t.print(c);
    t.setCursorPos(1, 4);
    t.eraseChars(10);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  A", str);
    }
}

test "Terminal: eraseChars preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
    defer t.deinit(alloc);

    const pen: Screen.Cell = .{
        .bg = .{ .r = 0xFF, .g = 0x00, .b = 0x00 },
        .attrs = .{ .has_bg = true },
    };

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.screen.cursor.pen = pen;
    t.eraseChars(2);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
        {
            const cell = t.screen.getCell(.active, 0, 0);
            try testing.expectEqual(pen, cell);
        }
        {
            const cell = t.screen.getCell(.active, 0, 1);
            try testing.expectEqual(pen, cell);
        }
    }
}

test "Terminal: eraseChars wide character" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.print('橋');
    for ("BC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseChars(1);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X BC", str);
    }
}

test "Terminal: eraseChars protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseChars(2);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

test "Terminal: eraseChars protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 1);
    t.eraseChars(2);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}

test "Terminal: eraseChars protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseChars(2);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}

// https://github.com/mitchellh/ghostty/issues/272
// This is also tested in depth in screen resize tests but I want to keep
// this test around to ensure we don't regress at multiple layers.
test "Terminal: resize less cols with wide char then print" {
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 3);
    defer t.deinit(alloc);

    try t.print('x');
    try t.print('😀'); // 0x1F600
    try t.resize(alloc, 2, 3);
    t.setCursorPos(1, 2);
    try t.print('😀'); // 0x1F600
}

test "Terminal: saveCursor" {
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 3);
    defer t.deinit(alloc);

    t.screen.cursor.pen.attrs.bold = true;
    t.screen.charset.gr = .G3;
    t.modes.set(.origin, true);
    t.saveCursor();
    t.screen.charset.gr = .G0;
    t.screen.cursor.pen.attrs.bold = false;
    t.modes.set(.origin, false);
    t.restoreCursor();
    try testing.expect(t.screen.cursor.pen.attrs.bold);
    try testing.expect(t.screen.charset.gr == .G3);
    try testing.expect(t.modes.get(.origin));
}

test "Terminal: saveCursor with screen change" {
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 3);
    defer t.deinit(alloc);

    t.screen.cursor.pen.attrs.bold = true;
    t.screen.cursor.x = 2;
    t.screen.charset.gr = .G3;
    t.modes.set(.origin, true);
    t.alternateScreen(alloc, .{
        .cursor_save = true,
        .clear_on_enter = true,
    });
    // make sure our cursor and charset have come with us
    try testing.expect(t.screen.cursor.pen.attrs.bold);
    try testing.expect(t.screen.cursor.x == 2);
    try testing.expect(t.screen.charset.gr == .G3);
    try testing.expect(t.modes.get(.origin));
    t.screen.charset.gr = .G0;
    t.screen.cursor.pen.attrs.bold = false;
    t.modes.set(.origin, false);
    t.primaryScreen(alloc, .{
        .cursor_save = true,
        .clear_on_enter = true,
    });
    try testing.expect(t.screen.cursor.pen.attrs.bold);
    try testing.expect(t.screen.charset.gr == .G3);
    try testing.expect(t.modes.get(.origin));
}

test "Terminal: setProtectedMode" {
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 3);
    defer t.deinit(alloc);

    try testing.expect(!t.screen.cursor.pen.attrs.protected);
    t.setProtectedMode(.off);
    try testing.expect(!t.screen.cursor.pen.attrs.protected);
    t.setProtectedMode(.iso);
    try testing.expect(t.screen.cursor.pen.attrs.protected);
    t.setProtectedMode(.dec);
    try testing.expect(t.screen.cursor.pen.attrs.protected);
    t.setProtectedMode(.off);
    try testing.expect(!t.screen.cursor.pen.attrs.protected);
}

test "Terminal: eraseLine simple erase right" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.eraseLine(.right, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB", str);
    }
}

test "Terminal: eraseLine resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.eraseLine(.right, false);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('B');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDB", str);
    }
}

test "Terminal: eraseLine right preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    const pen: Screen.Cell = .{
        .bg = .{ .r = 0xFF, .g = 0x00, .b = 0x00 },
        .attrs = .{ .has_bg = true },
    };

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.screen.cursor.pen = pen;
    t.eraseLine(.right, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
        for (1..5) |x| {
            const cell = t.screen.getCell(.active, 0, x);
            try testing.expectEqual(pen, cell);
        }
    }
}

test "Terminal: eraseLine right wide character" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    for ("AB") |c| try t.print(c);
    try t.print('橋');
    for ("DE") |c| try t.print(c);
    t.setCursorPos(1, 4);
    t.eraseLine(.right, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB", str);
    }
}

test "Terminal: eraseLine right protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseLine(.right, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

test "Terminal: eraseLine right protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 2);
    t.eraseLine(.right, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

test "Terminal: eraseLine right protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.eraseLine(.right, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

test "Terminal: eraseLine right protected requested" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    for ("12345678") |c| try t.print(c);
    t.setCursorPos(t.screen.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screen.cursor.y + 1, 4);
    t.eraseLine(.right, true);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("123  X", str);
    }
}

test "Terminal: eraseLine simple erase left" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.eraseLine(.left, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("   DE", str);
    }
}

test "Terminal: eraseLine left resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.eraseLine(.left, false);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('B');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    B", str);
    }
}

test "Terminal: eraseLine left preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    const pen: Screen.Cell = .{
        .bg = .{ .r = 0xFF, .g = 0x00, .b = 0x00 },
        .attrs = .{ .has_bg = true },
    };

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.screen.cursor.pen = pen;
    t.eraseLine(.left, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  CDE", str);
        for (0..2) |x| {
            const cell = t.screen.getCell(.active, 0, x);
            try testing.expectEqual(pen, cell);
        }
    }
}

test "Terminal: eraseLine left wide character" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    for ("AB") |c| try t.print(c);
    try t.print('橋');
    for ("DE") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.eraseLine(.left, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    DE", str);
    }
}

test "Terminal: eraseLine left protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseLine(.left, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

test "Terminal: eraseLine left protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 2);
    t.eraseLine(.left, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}

test "Terminal: eraseLine left protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.eraseLine(.left, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}

test "Terminal: eraseLine left protected requested" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screen.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screen.cursor.y + 1, 8);
    t.eraseLine(.left, true);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("     X  9", str);
    }
}

test "Terminal: eraseLine complete preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    const pen: Screen.Cell = .{
        .bg = .{ .r = 0xFF, .g = 0x00, .b = 0x00 },
        .attrs = .{ .has_bg = true },
    };

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.screen.cursor.pen = pen;
    t.eraseLine(.complete, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
        for (0..5) |x| {
            const cell = t.screen.getCell(.active, 0, x);
            try testing.expectEqual(pen, cell);
        }
    }
}

test "Terminal: eraseLine complete protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseLine(.complete, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

test "Terminal: eraseLine complete protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 2);
    t.eraseLine(.complete, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: eraseLine complete protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.eraseLine(.complete, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: eraseLine complete protected requested" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screen.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screen.cursor.y + 1, 8);
    t.eraseLine(.complete, true);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("     X", str);
    }
}

test "Terminal: eraseDisplay simple erase below" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(alloc, .below, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
    }
}

test "Terminal: eraseDisplay erase below preserves SGR bg" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);

    const pen: Screen.Cell = .{
        .bg = .{ .r = 0xFF, .g = 0x00, .b = 0x00 },
        .attrs = .{ .has_bg = true },
    };

    t.screen.cursor.pen = pen;
    t.eraseDisplay(alloc, .below, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
        for (1..5) |x| {
            const cell = t.screen.getCell(.active, 1, x);
            try testing.expectEqual(pen, cell);
        }
    }
}

test "Terminal: eraseDisplay below split multi-cell" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("AB橋C");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DE橋F");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GH橋I");
    t.setCursorPos(2, 4);
    t.eraseDisplay(alloc, .below, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB橋C\nDE", str);
    }
}

test "Terminal: eraseDisplay below protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(alloc, .below, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: eraseDisplay below protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(2, 2);
    t.eraseDisplay(alloc, .below, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
    }
}

test "Terminal: eraseDisplay below protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(alloc, .below, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
    }
}

test "Terminal: eraseDisplay simple erase above" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(alloc, .above, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
    }
}

test "Terminal: eraseDisplay below protected attributes respected with force" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(alloc, .below, true);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: eraseDisplay erase above preserves SGR bg" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);

    const pen: Screen.Cell = .{
        .bg = .{ .r = 0xFF, .g = 0x00, .b = 0x00 },
        .attrs = .{ .has_bg = true },
    };

    t.screen.cursor.pen = pen;
    t.eraseDisplay(alloc, .above, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
        for (0..2) |x| {
            const cell = t.screen.getCell(.active, 1, x);
            try testing.expectEqual(pen, cell);
        }
    }
}

test "Terminal: eraseDisplay above split multi-cell" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("AB橋C");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DE橋F");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GH橋I");
    t.setCursorPos(2, 3);
    t.eraseDisplay(alloc, .above, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n    F\nGH橋I", str);
    }
}

test "Terminal: eraseDisplay above protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(alloc, .above, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: eraseDisplay above protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(2, 2);
    t.eraseDisplay(alloc, .above, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
    }
}

test "Terminal: eraseDisplay above protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(alloc, .above, false);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
    }
}

test "Terminal: eraseDisplay above protected attributes respected with force" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(alloc, .above, true);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}
test "Terminal: eraseDisplay above" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    const pink = color.RGB{ .r = 0xFF, .g = 0x00, .b = 0x7F };
    t.screen.cursor.pen = Screen.Cell{
        .char = 'a',
        .bg = pink,
        .fg = pink,
        .attrs = .{ .bold = true, .has_bg = true },
    };
    const cell_ptr = t.screen.getCellPtr(.active, 0, 0);
    cell_ptr.* = t.screen.cursor.pen;
    // verify the cell was set
    var cell = t.screen.getCell(.active, 0, 0);
    try testing.expect(cell.bg.eql(pink));
    try testing.expect(cell.fg.eql(pink));
    try testing.expect(cell.char == 'a');
    try testing.expect(cell.attrs.bold);
    // move the cursor below it
    t.screen.cursor.y = 40;
    t.screen.cursor.x = 40;
    // erase above the cursor
    t.eraseDisplay(testing.allocator, .above, false);
    // check it was erased
    cell = t.screen.getCell(.active, 0, 0);
    try testing.expect(cell.bg.eql(pink));
    try testing.expect(cell.fg.eql(.{}));
    try testing.expect(cell.char == 0);
    try testing.expect(!cell.attrs.bold);
    try testing.expect(cell.attrs.has_bg);

    // Check that our pen hasn't changed
    try testing.expect(t.screen.cursor.pen.attrs.bold);

    // check that another cell got the correct bg
    cell = t.screen.getCell(.active, 0, 1);
    try testing.expect(cell.bg.eql(pink));
}

test "Terminal: eraseDisplay below" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    const pink = color.RGB{ .r = 0xFF, .g = 0x00, .b = 0x7F };
    t.screen.cursor.pen = Screen.Cell{
        .char = 'a',
        .bg = pink,
        .fg = pink,
        .attrs = .{ .bold = true, .has_bg = true },
    };
    const cell_ptr = t.screen.getCellPtr(.active, 60, 60);
    cell_ptr.* = t.screen.cursor.pen;
    // verify the cell was set
    var cell = t.screen.getCell(.active, 60, 60);
    try testing.expect(cell.bg.eql(pink));
    try testing.expect(cell.fg.eql(pink));
    try testing.expect(cell.char == 'a');
    try testing.expect(cell.attrs.bold);
    // erase below the cursor
    t.eraseDisplay(testing.allocator, .below, false);
    // check it was erased
    cell = t.screen.getCell(.active, 60, 60);
    try testing.expect(cell.bg.eql(pink));
    try testing.expect(cell.fg.eql(.{}));
    try testing.expect(cell.char == 0);
    try testing.expect(!cell.attrs.bold);
    try testing.expect(cell.attrs.has_bg);

    // check that another cell got the correct bg
    cell = t.screen.getCell(.active, 0, 1);
    try testing.expect(cell.bg.eql(pink));
}

test "Terminal: eraseDisplay complete" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    const pink = color.RGB{ .r = 0xFF, .g = 0x00, .b = 0x7F };
    t.screen.cursor.pen = Screen.Cell{
        .char = 'a',
        .bg = pink,
        .fg = pink,
        .attrs = .{ .bold = true, .has_bg = true },
    };
    var cell_ptr = t.screen.getCellPtr(.active, 60, 60);
    cell_ptr.* = t.screen.cursor.pen;
    cell_ptr = t.screen.getCellPtr(.active, 0, 0);
    cell_ptr.* = t.screen.cursor.pen;
    // verify the cell was set
    var cell = t.screen.getCell(.active, 60, 60);
    try testing.expect(cell.bg.eql(pink));
    try testing.expect(cell.fg.eql(pink));
    try testing.expect(cell.char == 'a');
    try testing.expect(cell.attrs.bold);
    // verify the cell was set
    cell = t.screen.getCell(.active, 0, 0);
    try testing.expect(cell.bg.eql(pink));
    try testing.expect(cell.fg.eql(pink));
    try testing.expect(cell.char == 'a');
    try testing.expect(cell.attrs.bold);
    // position our cursor between the cells
    t.screen.cursor.y = 30;
    // erase everything
    t.eraseDisplay(testing.allocator, .complete, false);
    // check they were erased
    cell = t.screen.getCell(.active, 60, 60);
    try testing.expect(cell.bg.eql(pink));
    try testing.expect(cell.fg.eql(.{}));
    try testing.expect(cell.char == 0);
    try testing.expect(!cell.attrs.bold);
    try testing.expect(cell.attrs.has_bg);
    cell = t.screen.getCell(.active, 0, 0);
    try testing.expect(cell.bg.eql(pink));
    try testing.expect(cell.fg.eql(.{}));
    try testing.expect(cell.char == 0);
    try testing.expect(!cell.attrs.bold);
    try testing.expect(cell.attrs.has_bg);
}

test "Terminal: eraseDisplay protected complete" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screen.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screen.cursor.y + 1, 4);
    t.eraseDisplay(alloc, .complete, true);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n     X", str);
    }
}

test "Terminal: eraseDisplay protected below" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screen.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screen.cursor.y + 1, 4);
    t.eraseDisplay(alloc, .below, true);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n123  X", str);
    }
}

test "Terminal: eraseDisplay protected above" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screen.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screen.cursor.y + 1, 8);
    t.eraseDisplay(alloc, .above, true);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n     X  9", str);
    }
}

test "Terminal: cursorLeft no wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.cursorLeft(10);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nB", str);
    }
}

test "Terminal: cursorLeft unsets pending wrap state" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.cursorLeft(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: cursorLeft unsets pending wrap state with longer jump" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.cursorLeft(3);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABXDE", str);
    }
}

test "Terminal: cursorLeft reverse wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);

    for ("ABCDE1") |c| try t.print(c);
    t.cursorLeft(2);
    try t.print('X');
    try testing.expect(t.screen.cursor.pending_wrap);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX\n1", str);
    }
}

test "Terminal: cursorLeft reverse wrap with no soft wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);

    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(2);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\nX", str);
    }
}

test "Terminal: cursorLeft extended reverse wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);

    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(2);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX\n1", str);
    }
}

test "Terminal: cursorLeft extended reverse wrap bottom wraparound" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 3);
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);

    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(1 + t.cols + 1);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\n1\n    X", str);
    }
}

test "Terminal: cursorLeft extended reverse wrap is priority if both set" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 3);
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);
    t.modes.set(.reverse_wrap_extended, true);

    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(1 + t.cols + 1);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\n1\n    X", str);
    }
}

test "Terminal: cursorDown basic" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.print('A');
    t.cursorDown(10);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n\n\n X", str);
    }
}

test "Terminal: cursorDown above bottom scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setScrollingRegion(1, 3);
    try t.print('A');
    t.cursorDown(10);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n X", str);
    }
}

test "Terminal: cursorDown below bottom scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setScrollingRegion(1, 3);
    try t.print('A');
    t.setCursorPos(4, 1);
    t.cursorDown(10);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n\n\nX", str);
    }
}

test "Terminal: cursorDown resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.cursorDown(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\n    X", str);
    }
}

test "Terminal: cursorUp basic" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setCursorPos(3, 1);
    try t.print('A');
    t.cursorUp(10);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" X\n\nA", str);
    }
}

test "Terminal: cursorUp below top scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setScrollingRegion(2, 4);
    t.setCursorPos(3, 1);
    try t.print('A');
    t.cursorUp(5);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n X\nA", str);
    }
}

test "Terminal: cursorUp above top scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setScrollingRegion(3, 5);
    t.setCursorPos(3, 1);
    try t.print('A');
    t.setCursorPos(2, 1);
    t.cursorUp(10);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\n\nA", str);
    }
}

test "Terminal: cursorUp resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.cursorUp(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: cursorRight resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.cursorRight(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: cursorRight to the edge of screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.cursorRight(100);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    X", str);
    }
}

test "Terminal: cursorRight left of right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.scrolling_region.right = 2;
    t.cursorRight(100);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X", str);
    }
}

test "Terminal: cursorRight right of right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.scrolling_region.right = 2;
    t.screen.cursor.x = 3;
    t.cursorRight(100);
    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    X", str);
    }
}
