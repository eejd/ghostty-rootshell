const std = @import("std");
const assert = std.debug.assert;

/// Synthetic OSC request generator.
///
/// I tried to balance generality and practicality. I implemented mainly
/// all I need at the time of writing this, but I think this can be iterated
/// over time to be a general purpose OSC generator with a lot of
/// configurability. I limited the configurability to what I need but still
/// tried to lay out the code in a way that it can be extended easily.
pub const Generator = struct {
    /// Random number generator.
    rand: std.Random,

    /// Probability of a valid OSC sequence being generated.
    p_valid: f64 = 1.0,

    pub const Error = error{NoSpaceLeft};

    /// We use a FBS as a direct parameter below in non-pub functions,
    /// but we should probably just switch to `[]u8`.
    const FBS = std.io.FixedBufferStream([]u8);

    /// Get the next OSC request in bytes. The generated OSC request will
    /// have the prefix `ESC ]` and the terminator `BEL` (0x07).
    ///
    /// This will generate both valid and invalid OSC requests (based on
    /// the `p_valid` probability value). Invalid requests still have the
    /// prefix and terminator, but the content in between is not a valid
    /// OSC request.
    ///
    /// The buffer must be at least 3 bytes long to accommodate the
    /// prefix and terminator.
    pub fn next(self: *const Generator, buf: []u8) Error![]const u8 {
        assert(buf.len >= 3);
        var fbs: FBS = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        // Start OSC (ESC ])
        try writer.writeAll("\x1b]");

        // Determine if we are generating a valid or invalid OSC request.
        switch (self.chooseValidity()) {
            .valid => try self.nextValid(&fbs),
            .invalid => try self.nextInvalid(&fbs),
        }

        // Terminate OSC
        try writer.writeAll("\x07");
        return fbs.getWritten();
    }

    fn nextValid(self: *const Generator, fbs: *FBS) Error!void {
        try self.nextValidExact(fbs, self.rand.enumValue(ValidKind));
    }

    fn nextValidExact(self: *const Generator, fbs: *FBS, k: ValidKind) Error!void {
        switch (k) {
            .change_window_title => {
                try fbs.writer().writeAll("0;"); // Set window title
                try self.randomBytes(fbs, 1, fbs.buffer.len);
            },

            .prompt_start => {
                try fbs.writer().writeAll("133;A"); // Start prompt

                // aid
                if (self.rand.boolean()) {
                    try fbs.writer().writeAll(";aid=");
                    try self.randomBytes(fbs, 1, 16);
                }

                // redraw
                if (self.rand.boolean()) {
                    try fbs.writer().writeAll(";redraw=");
                    if (self.rand.boolean()) {
                        try fbs.writer().writeAll("1");
                    } else {
                        try fbs.writer().writeAll("0");
                    }
                }
            },

            .prompt_end => try fbs.writer().writeAll("133;B"), // End prompt
        }
    }

    fn nextInvalid(self: *const Generator, fbs: *FBS) Error!void {
        switch (self.rand.enumValue(InvalidKind)) {
            .random => try self.randomBytes(fbs, 1, fbs.buffer.len),
            .good_prefix => {
                try fbs.writer().writeAll("133;");
                try self.randomBytes(fbs, 2, fbs.buffer.len);
            },
        }
    }

    /// Generate a random string of bytes up to `max_len` bytes or
    /// until we run out of space in the buffer, whichever is
    /// smaller.
    ///
    /// This will avoid the terminator characters (0x1B and 0x07) and
    /// replace them by incrementing them by one.
    fn randomBytes(
        self: *const Generator,
        fbs: *FBS,
        min_len: usize,
        max_len: usize,
    ) Error!void {
        const len = @min(
            self.rand.intRangeAtMostBiased(usize, min_len, max_len),
            fbs.buffer.len - fbs.pos - 1, // leave space for terminator
        );
        var rem: usize = len;
        var buf: [1024]u8 = undefined;
        while (rem > 0) {
            self.rand.bytes(&buf);
            std.mem.replaceScalar(u8, &buf, 0x1B, 0x1C);
            std.mem.replaceScalar(u8, &buf, 0x07, 0x08);

            const n = @min(rem, buf.len);
            try fbs.writer().writeAll(buf[0..n]);
            rem -= n;
        }
    }

    /// Choose whether to generate a valid or invalid OSC request based
    /// on the validity probability.
    fn chooseValidity(self: *const Generator) Validity {
        return if (self.rand.float(f64) > self.p_valid)
            .invalid
        else
            .valid;
    }

    const Validity = enum { valid, invalid };

    const ValidKind = enum {
        change_window_title,
        prompt_start,
        prompt_end,
    };

    const InvalidKind = enum {
        /// Literally random bytes. Might even be valid, but probably not.
        random,

        /// A good prefix, but ultimately invalid format.
        good_prefix,
    };
};

/// A fixed seed we can use for our tests to avoid flakes.
const test_seed = 0xC0FFEEEEEEEEEEEE;

test "OSC generator" {
    var prng = std.Random.DefaultPrng.init(test_seed);
    var buf: [4096]u8 = undefined;
    const gen: Generator = .{ .rand = prng.random() };
    for (0..50) |_| _ = try gen.next(&buf);
}

test "OSC generator valid" {
    const testing = std.testing;
    const terminal = @import("../../terminal/main.zig");

    var prng = std.Random.DefaultPrng.init(test_seed);
    var buf: [256]u8 = undefined;
    const gen: Generator = .{
        .rand = prng.random(),
        .p_valid = 1.0,
    };
    for (0..50) |_| {
        const seq = try gen.next(&buf);
        var parser: terminal.osc.Parser = .{};
        for (seq[2 .. seq.len - 1]) |c| parser.next(c);
        try testing.expect(parser.end(null) != null);
    }
}

test "OSC generator invalid" {
    const testing = std.testing;
    const terminal = @import("../../terminal/main.zig");

    var prng = std.Random.DefaultPrng.init(test_seed);
    var buf: [256]u8 = undefined;
    const gen: Generator = .{
        .rand = prng.random(),
        .p_valid = 0.0,
    };
    for (0..50) |_| {
        const seq = try gen.next(&buf);
        var parser: terminal.osc.Parser = .{};
        for (seq[2 .. seq.len - 1]) |c| parser.next(c);
        try testing.expect(parser.end(null) == null);
    }
}
