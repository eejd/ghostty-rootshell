const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Terminal = ghostty_vt.Terminal;
const ReadonlyStream = ghostty_vt.ReadonlyStream;

/// Fixed-capacity allocator that avoids heap allocation and gives the
/// fuzzer deterministic, bounded memory behaviour. Backed by a single
/// fixed buffer; every `reset()` returns the bump pointer to the start
/// so the same memory is reused across iterations.
const FuzzAllocator = struct {
    buf: [mem_size]u8 = undefined,
    state: std.heap.FixedBufferAllocator = undefined,

    /// 4 MiB is plenty for a small terminal with a few pages of
    /// scrollback, while staying within the resident-set limits
    /// that AFL++ expects.
    const mem_size = 4 * 1024 * 1024;

    fn init(self: *FuzzAllocator) void {
        self.state = std.heap.FixedBufferAllocator.init(&self.buf);
    }

    fn allocator(self: *FuzzAllocator) std.mem.Allocator {
        return self.state.allocator();
    }

    fn reset(self: *FuzzAllocator) void {
        self.state.reset();
    }
};

var fuzz_alloc: FuzzAllocator = .{};

pub export fn zig_fuzz_init() callconv(.c) void {
    fuzz_alloc.init();
}

pub export fn zig_fuzz_test(
    buf: [*]const u8,
    len: usize,
) callconv(.c) void {
    fuzz_alloc.reset();
    const alloc = fuzz_alloc.allocator();
    const input = buf[0..@intCast(len)];

    // Allocate a terminal; if we run out of fixed-buffer space just
    // skip this input (not a bug, just a very large allocation).
    var term = Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 100,
    }) catch return;
    defer term.deinit(alloc);

    var stream: ReadonlyStream = term.vtStream();
    defer stream.deinit();

    // Use the first byte to decide between the scalar and slice paths
    // so both code paths get exercised by the fuzzer.
    if (input.len == 0) return;
    const mode = input[0];
    const data = input[1..];

    if (mode & 1 == 0) {
        // Slice path — exercises SIMD fast-path
        stream.nextSlice(data) catch {};
    } else {
        // Scalar path — exercises byte-at-a-time UTF-8 decoding
        for (data) |byte| _ = stream.next(byte) catch {};
    }
}
