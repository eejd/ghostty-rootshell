const std = @import("std");
const Source = @import("Source.zig");

/// Ghostty's terminfo entry.
pub const ghostty: Source = .{
    .names = &.{
        "ghostty",
        "xterm-ghostty",
        "Ghostty",
    },

    // NOTE: These capabilities are super underdocumented and I'm not 100%
    // I've got the list or my understanding of any in this list fully correct.
    // As we learn more, please update the comments to better explain what
    // anything means.
    //
    // I've marked some capabilities as "???" if I don't understand what they
    // mean but I just assume I support since other modern terminals do. In
    // this case, I'd love if anyone could help explain what this means and
    // verify that Ghostty does indeed support it and if not we can fix it.
    .capabilities = &.{
        // automatic right margin -- when reaching the end of a line, text is
        // wrapped to the next line.
        .{ .name = "am", .value = .{ .boolean = {} } },

        // background color erase -- screen is erased with the background color
        .{ .name = "bce", .value = .{ .boolean = {} } },

        // terminal can change color definitions, i.e. we can change the color
        // palette. TODO: this may require implementing CSI 4 which we don't
        // at the time of writing this comment.
        .{ .name = "ccc", .value = .{ .boolean = {} } },

        // supports changing the window title.
        .{ .name = "hs", .value = .{ .boolean = {} } },

        // terminal has a meta key
        .{ .name = "km", .value = .{ .boolean = {} } },

        // terminal will not echo input on the screen on its own
        .{ .name = "mc5i", .value = .{ .boolean = {} } },

        // safe to move (move what?) while in insert/standout mode. (???)
        .{ .name = "mir", .value = .{ .boolean = {} } },
        .{ .name = "msgr", .value = .{ .boolean = {} } },

        // no pad character (???)
        .{ .name = "npc", .value = .{ .boolean = {} } },

        // newline ignored after 80 cols (???)
        .{ .name = "xenl", .value = .{ .boolean = {} } },

        // Tmux "truecolor" mode. Other programs also use this to detect
        // if the terminal supports "truecolor". This means that the terminal
        // can display 24-bit RGB colors.
        .{ .name = "Tc", .value = .{ .boolean = {} } },

        // Colored underlines. https://sw.kovidgoyal.net/kitty/underlines/
        .{ .name = "Su", .value = .{ .boolean = {} } },

        // Full keyboard support using Kitty's keyboard protocol:
        // https://sw.kovidgoyal.net/kitty/keyboard-protocol/
        // Commented out because we don't yet support this.
        // .{ .name = "fullkbd", .value = .{ .boolean = {} } },

        // Number of colors in the color palette.
        .{ .name = "colors", .value = .{ .numeric = 256 } },

        // Number of columns in a line. Our terminal is variable width on
        // Window resize but this appears to just be the value set by most
        // terminals.
        .{ .name = "cols", .value = .{ .numeric = 80 } },

        // Initial tabstop interval.
        .{ .name = "it", .value = .{ .numeric = 8 } },

        // Number of lines on a page. Similar to cols this is variable width
        // but this appears to be the value set by most terminals.
        .{ .name = "lines", .value = .{ .numeric = 24 } },

        // Number of color pairs on the screen.
        .{ .name = "pairs", .value = .{ .numeric = 32767 } },
    },
};

test "encode" {
    // Encode
    var buf: [1024]u8 = undefined;
    var buf_stream = std.io.fixedBufferStream(&buf);
    try ghostty.encode(buf_stream.writer());
    try std.testing.expect(buf_stream.getWritten().len > 0);
}
