//! This benchmark tests the throughput of the VT stream. It has a few
//! modes in order to test different methods of stream processing. It
//! provides a "noop" mode to give us the `memcpy` speed.
//!
//! This will consume all of the available stdin, so you should run it
//! with `head` in a pipe to restrict. For example, to test ASCII input:
//!
//!   bench-stream --mode=gen-ascii | head -c 50M | bench-stream --mode=simd
//!

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ziglyph = @import("ziglyph");
const cli = @import("../cli.zig");
const terminal = @import("../terminal/main.zig");

const Args = struct {
    mode: Mode = .noop,

    /// Process input with a real terminal. This will be MUCH slower than
    /// the other modes because it has to maintain terminal state but will
    /// help get more realistic numbers.
    terminal: bool = false,
    @"terminal-rows": usize = 80,
    @"terminal-cols": usize = 120,

    /// The size for read buffers. Doesn't usually need to be changed. The
    /// main point is to make this runtime known so we can avoid compiler
    /// optimizations.
    @"buffer-size": usize = 4096,

    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    pub fn deinit(self: *Args) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

const Mode = enum {
    // Do nothing, just read from stdin into a stack-allocated buffer.
    // This is used to benchmark our base-case: it gives us our maximum
    // throughput on a basic read.
    noop,

    // These benchmark the throughput of the terminal stream parsing
    // with and without SIMD. The "simd" option will use whatever is best
    // for the running platform.
    //
    // Note that these run through the full VT parser but do not apply
    // the operations to terminal state, so there is no terminal state
    // overhead.
    scalar,
    simd,

    // Generate an infinite stream of random printable ASCII characters.
    @"gen-ascii",

    // Generate an infinite stream of repeated UTF-8 characters. We don't
    // currently do random generation because trivial implementations are
    // too slow and I'm a simple man.
    @"gen-utf8",
};

pub const std_options = struct {
    pub const log_level: std.log.Level = .debug;
};

pub fn main() !void {
    // We want to use the c allocator because it is much faster than GPA.
    const alloc = std.heap.c_allocator;

    // Parse our args
    var args: Args = .{};
    defer args.deinit();
    {
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        try cli.args.parse(Args, alloc, &args, &iter);
    }

    const reader = std.io.getStdIn().reader();
    const writer = std.io.getStdOut().writer();
    const buf = try alloc.alloc(u8, args.@"buffer-size");

    // Handle the modes that do not depend on terminal state first.
    switch (args.mode) {
        .@"gen-ascii" => try genAscii(writer),
        .@"gen-utf8" => try genUtf8(writer),
        .noop => try benchNoop(reader, buf),

        // Handle the ones that depend on terminal state next
        inline .scalar,
        .simd,
        => |tag| {
            if (args.terminal) {
                const TerminalStream = terminal.Stream(*TerminalHandler);
                var t = try terminal.Terminal.init(
                    alloc,
                    args.@"terminal-cols",
                    args.@"terminal-rows",
                );
                var handler: TerminalHandler = .{ .t = &t };
                var stream: TerminalStream = .{ .handler = &handler };
                switch (tag) {
                    .scalar => try benchScalar(reader, &stream, buf),
                    .simd => try benchSimd(reader, &stream, buf),
                    else => @compileError("missing case"),
                }
            } else {
                var stream: terminal.Stream(NoopHandler) = .{ .handler = .{} };
                switch (tag) {
                    .scalar => try benchScalar(reader, &stream, buf),
                    .simd => try benchSimd(reader, &stream, buf),
                    else => @compileError("missing case"),
                }
            }
        },
    }
}

/// Generates an infinite stream of random printable ASCII characters.
/// This has no control characters in it at all.
fn genAscii(writer: anytype) !void {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;':\\\",./<>?`~";
    try genData(writer, alphabet);
}

/// Generates an infinite stream of bytes from the given alphabet.
fn genData(writer: anytype, alphabet: []const u8) !void {
    var prng = std.rand.DefaultPrng.init(0x12345678);
    const rnd = prng.random();
    while (true) {
        var buf: [1024]u8 = undefined;
        for (&buf) |*c| {
            const idx = rnd.uintLessThanBiased(usize, alphabet.len);
            c.* = alphabet[idx];
        }

        writer.writeAll(&buf) catch |err| switch (err) {
            error.BrokenPipe => return, // stdout closed
            else => return err,
        };
    }
}

fn genUtf8(writer: anytype) !void {
    while (true) {
        writer.writeAll(random_utf8) catch |err| switch (err) {
            error.BrokenPipe => return, // stdout closed
            else => return err,
        };
    }
}

noinline fn benchNoop(reader: anytype, buf: []u8) !void {
    var total: usize = 0;
    while (true) {
        const n = try reader.readAll(buf);
        if (n == 0) break;
        total += n;
    }

    std.log.info("total bytes len={}", .{total});
}

noinline fn benchScalar(
    reader: anytype,
    stream: anytype,
    buf: []u8,
) !void {
    while (true) {
        const n = try reader.read(buf);
        if (n == 0) break;

        // Using stream.next directly with a for loop applies a naive
        // scalar approach.
        for (buf[0..n]) |c| try stream.next(c);
    }
}

noinline fn benchSimd(
    reader: anytype,
    stream: anytype,
    buf: []u8,
) !void {
    while (true) {
        const n = try reader.read(buf);
        if (n == 0) break;
        try stream.nextSlice(buf[0..n]);
    }
}

const NoopHandler = struct {
    pub fn print(self: NoopHandler, cp: u21) !void {
        _ = self;
        _ = cp;
    }
};

const TerminalHandler = struct {
    t: *terminal.Terminal,

    pub fn print(self: *TerminalHandler, cp: u21) !void {
        try self.t.print(cp);
    }
};

/// Offline-generated random UTF-8 bytes, because generating them at runtime
/// was too slow for our benchmarks. We should replace this if we can come
/// up with something that doesn't bottleneck our benchmark.
const random_utf8 = "⨴⭬∎⯀Ⳟ⳨⍈♍⒄⣹⇚ⱎ⯡⯴↩ⵆ⼳ⶦ⑑⦥➍Ⲡ⽉❞⹀⢧€⣁ⶐ⸲⣷⏝⣶⫿▝⨽⬃ↁ↵⯙ⶵ╡∾⭡′⫼↼┫⮡ↅ⍞‡▱⺁⿒⽛⎭☜Ⱝ⣘✬⢟⁴⟹⪝ℌ❓␆╣┳⽑⴩⺄✽ⳗ␮ⵍ⦵ⱍ⭑⛒ⅉ⛠➌₯ⵔⷋ⹶❷ⱳ⣖⭐⮋ₒ⥚ⷃ╶⌈⸣❥⑎⦿⪶₮╋⅌ⳬⴛ⥚♇╬❜⺷⡬⏠⧥┺⃻❼⏲↍Ⓙ⽕╶⾉⺪⁑⎕⅕⼧⊀ⲡ⊺⪭⟾Ⅵ⍌⛄⠻⃽⣻₮ⰹⴺ⪂⃾∖⊹⤔⵫⦒⽳⫄⍮↷⣌⩐⨼⯂⵺◺⍙⭺⟂⎯ⱼ⴬⫺⹦∌⡉ⳅ⛲⡏⃘⺃⵬ⴜ⾩⭦ⷭ⨟☌⍃⧪⮧ⓛ⃄♮ⲓ∘⣝⤐⎭ⷺⰫⶔ☎⾨⾐≦␢⋔⢟ⶐ⏁⚄⦡⾞✊⾾⫿⴩⪨⮰ⓙ⌽⭲⫬⒈⊻⸣⌳⋡ⱄⲛ⓬➼⌧⟮⹖♞ℚⷱ⭥⚣⏳⟾❠☏⦻⑽−∪ⅆ☁⿑⦣⵽Ⱳ⺧⺊Ⓞ⫽⦀⃐⚽⎌⥰⚪⢌⛗⸋⛂⾽Ⰳ⍧⛗◁❠↺≍‸ⴣ⭰‾⡸⩛⭷ⵒ⵼⚉❚⨳⑫⹾⷟∇┬⚌⨙╘ℹ⢱⏴∸⴨⾀⌟⡄⺣⦦ⱏ⼚​⿇├⌮⸿⯔₮—⥟╖◡⻵ⶕ┧⒞⏖⏧⟀❲➚‏➳Ⰼ┸⬖⸓⁃⹚⫣┭↜〈☶≍☨╟⿹ⳙ⺽⸡⵵⛞⚟⯓⥟┞⿄⮖⃫⭒⠤ⓣ⬱⃅⓼ⱒ⥖✜⛘⠶ⰽ⿉⾣➌⣋⚨⒯◱⢃◔ⱕ⫡⓱⅌Ⱨ⧵⯾┰⁠ⱌ⼳♠⨽⪢⸳⠹⩡Ⓨ⡪⭞⼰⡧ⓖ⤘⽶⵶ⴺ ⨨▅⏟⊕ⴡⴰ␌⚯⦀⫭⨔⬯⨢ⱽ⟓⥫⑤⊘⟧❐▜⵸℅⋣⚏⇭⽁⪂ⲡ⯊⦥⭳⠾⹫⠮℞⒡Ⰼ⦈⭅≉⋆☈▓⺑⡻▷Ⱑ⋖⬜┃ⵍ←⣢ↁ☚⟴⦡⨍⼡◝⯤❓◢⌡⏿⭲✏⎑⧊⼤⪠⋂⚜┯▤⑘⟾⬬Ⓜ⨸⥪ⱘ⳷⷟⒖⋐⡈⏌∠⏁⓳Ⲟ⦽⢯┏Ⲹ⍰ⅹ⚏⍐⟍⣩␖⛂∜❆⤗⒨⓽";
