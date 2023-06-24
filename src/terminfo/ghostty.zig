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

        // Alternate character set. This is the VT100 alternate character set.
        // I don't know what the value means, I copied this from Kitty and
        // verified with some other terminals (looks similar).
        .{ .name = "acsc", .value = .{ .string = "++\\,\\,--..00``aaffgghhiijjkkllmmnnooppqqrrssttuuvvwwxxyyzz{{||}}~~" } },

        // These are all capabilities that should be pretty straightforward
        // and map to input sequences.
        .{ .name = "bel", .value = .{ .string = "^G" } },
        .{ .name = "blink", .value = .{ .string = "\\E[5m" } },
        .{ .name = "bold", .value = .{ .string = "\\E[1m" } },
        .{ .name = "cbt", .value = .{ .string = "\\E[Z" } },
        .{ .name = "civis", .value = .{ .string = "\\E[?25l" } },
        .{ .name = "clear", .value = .{ .string = "\\E[H\\E[2J" } },
        .{ .name = "cnorm", .value = .{ .string = "\\E[?25h" } },
        .{ .name = "cr", .value = .{ .string = "\\r" } },
        .{ .name = "csr", .value = .{ .string = "\\E[%i%p1%d;%p2%dr" } },
        .{ .name = "cub", .value = .{ .string = "\\E[%p1%dD" } },
        .{ .name = "cub1", .value = .{ .string = "^H" } },
        .{ .name = "cud", .value = .{ .string = "\\E[%p1%dB" } },
        .{ .name = "cud1", .value = .{ .string = "^J" } },
        .{ .name = "cuf", .value = .{ .string = "\\E[%p1%dC" } },
        .{ .name = "cuf1", .value = .{ .string = "\\E[C" } },
        .{ .name = "cup", .value = .{ .string = "\\E[%i%p1%d;%p2%dH" } },
        .{ .name = "cuu", .value = .{ .string = "\\E[%p1%dA" } },
        .{ .name = "cuu1", .value = .{ .string = "\\E[A" } },
        .{ .name = "cvvis", .value = .{ .string = "\\E[?12;25h" } },
        .{ .name = "dch", .value = .{ .string = "\\E[%p1%dP" } },
        .{ .name = "dch1", .value = .{ .string = "\\E[P" } },
        .{ .name = "dim", .value = .{ .string = "\\E[2m" } },
        .{ .name = "dl", .value = .{ .string = "\\E[%p1%dM" } },
        .{ .name = "dl1", .value = .{ .string = "\\E[M" } },
        .{ .name = "dsl", .value = .{ .string = "\\E]2;\\007" } },
        .{ .name = "ech", .value = .{ .string = "\\E[%p1%dX" } },
        .{ .name = "ed", .value = .{ .string = "\\E[J" } },
        .{ .name = "el", .value = .{ .string = "\\E[K" } },
        .{ .name = "el1", .value = .{ .string = "\\E[1K" } },
        .{ .name = "flash", .value = .{ .string = "\\E[?5h$<100/>\\E[?5l" } },
        .{ .name = "fsl", .value = .{ .string = "^G" } },
        .{ .name = "home", .value = .{ .string = "\\E[H" } },
        .{ .name = "hpa", .value = .{ .string = "\\E[%i%p1%dG" } },
        .{ .name = "ht", .value = .{ .string = "^I" } },
        .{ .name = "hts", .value = .{ .string = "\\EH" } },
        .{ .name = "ich", .value = .{ .string = "\\E[%p1%d@" } },
        .{ .name = "il", .value = .{ .string = "\\E[%p1%dL" } },
        .{ .name = "il1", .value = .{ .string = "\\E[L" } },
        .{ .name = "ind", .value = .{ .string = "\\n" } },
        .{ .name = "indn", .value = .{ .string = "\\E[%p1%dS" } },
        .{ .name = "initc", .value = .{ .string = "\\E]4;%p1%d;rgb\\:%p2%{255}%*%{1000}%/%2.2X/%p3%{255}%*%{1000}%/%2.2X/%p4%{255}%*%{1000}%/%2.2X\\E\\\\" } },
        .{ .name = "invis", .value = .{ .string = "\\E[8m" } },
    },
};

test "encode" {
    // Encode
    var buf: [1024]u8 = undefined;
    var buf_stream = std.io.fixedBufferStream(&buf);
    try ghostty.encode(buf_stream.writer());
    try std.testing.expect(buf_stream.getWritten().len > 0);
}
