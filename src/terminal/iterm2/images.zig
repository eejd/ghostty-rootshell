//! iTerm2 inline image protocol (OSC 1337).
//!
//! This implements:
//!   - OSC 1337 ; File=[args]:<base64 payload>                 (legacy one-shot)
//!   - OSC 1337 ; MultipartFile=[args]                         (chunked header)
//!   - OSC 1337 ; FilePart=<base64 chunk>                      (chunked data)
//!   - OSC 1337 ; FileEnd                                      (chunked terminator)
//!
//! Spec: https://iterm2.com/documentation-images.html
//!
//! Strategy: parse the iTerm2 args + data, decode the payload (PNG/JPEG via
//! wuffs) to RGBA pixels, then hand off to Ghostty's existing Kitty graphics
//! pipeline by constructing an equivalent Kitty Command and calling
//! kitty.graphics.execute(). This reuses the image store, placement logic,
//! rendering, and cursor movement.

const std = @import("std");
const build_options = @import("terminal_options");
const Allocator = std.mem.Allocator;

const assert = @import("../../quirks.zig").inlineAssert;
const simd = @import("../../simd/main.zig");
const wuffs = @import("wuffs");

const kitty_command = @import("../kitty/graphics_command.zig");
const kitty_exec = @import("../kitty/graphics_exec.zig");
const kitty_image = @import("../kitty/graphics_image.zig");
const Terminal = @import("../Terminal.zig");

const log = std.log.scoped(.iterm2_image);

/// Maximum bytes we'll accept for a single iTerm2 image (matches Kitty cap).
const max_bytes: usize = 400 * 1024 * 1024;

/// A parsed iTerm2 File= / MultipartFile= argument bundle.
pub const Meta = struct {
    /// True if we should render inline (vs download - we only support inline).
    /// Defaults to false; imgcat always sets inline=1.
    inline_: bool = false,

    /// Expected decoded payload size in bytes (optional hint; we don't enforce).
    size: ?u64 = null,

    /// Width of the displayed image.
    width: Dim = .auto,

    /// Height of the displayed image.
    height: Dim = .auto,

    /// If true (default), the image is scaled to fit within the given width
    /// and height while preserving aspect ratio.
    preserve_aspect_ratio: bool = true,

    /// If true, the cursor is not moved past the image after rendering.
    do_not_move_cursor: bool = false,

    pub const Dim = union(enum) {
        /// No dimension specified; auto-size from the image and cell grid.
        auto,
        /// A specific number of terminal character cells.
        cells: u32,
        /// A specific number of pixels.
        pixels: u32,
        /// A percentage of the terminal width (height).
        percent: u32,

        /// Parse a single iTerm2 dimension spec. Accepts:
        ///   "auto"  -> .auto
        ///   "42"    -> .cells (N character cells)
        ///   "42px"  -> .pixels (N pixels)
        ///   "42%"   -> .percent (N percent)
        fn parse(s: []const u8) !Dim {
            if (s.len == 0) return .auto;
            if (std.mem.eql(u8, s, "auto")) return .auto;

            if (std.mem.endsWith(u8, s, "px")) {
                const n = try std.fmt.parseInt(u32, s[0 .. s.len - 2], 10);
                return .{ .pixels = n };
            }

            if (std.mem.endsWith(u8, s, "%")) {
                const n = try std.fmt.parseInt(u32, s[0 .. s.len - 1], 10);
                return .{ .percent = n };
            }

            const n = try std.fmt.parseInt(u32, s, 10);
            return .{ .cells = n };
        }
    };

    /// Parse the iTerm2 argument list. The input is the portion after the
    /// `File=` or `MultipartFile=` key and before any trailing `:` (for
    /// legacy single-shot mode); i.e. a semicolon-separated list of
    /// `key=value` pairs.
    pub fn parse(args: []const u8) Meta {
        var result: Meta = .{};

        var it = std.mem.splitScalar(u8, args, ';');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const value = pair[eq + 1 ..];

            if (std.ascii.eqlIgnoreCase(key, "inline")) {
                result.inline_ = std.mem.eql(u8, value, "1");
            } else if (std.ascii.eqlIgnoreCase(key, "size")) {
                result.size = std.fmt.parseInt(u64, value, 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(key, "width")) {
                result.width = Dim.parse(value) catch .auto;
            } else if (std.ascii.eqlIgnoreCase(key, "height")) {
                result.height = Dim.parse(value) catch .auto;
            } else if (std.ascii.eqlIgnoreCase(key, "preserveAspectRatio")) {
                result.preserve_aspect_ratio = !std.mem.eql(u8, value, "0");
            } else if (std.ascii.eqlIgnoreCase(key, "doNotMoveCursor")) {
                result.do_not_move_cursor = std.mem.eql(u8, value, "1");
            }
            // name=, type= are accepted and ignored
        }

        return result;
    }
};

/// In-progress iTerm2 image load (for MultipartFile chunked mode).
/// Stored on ImageStorage.iterm2_loading while FilePart chunks arrive.
pub const Loading = struct {
    meta: Meta,
    /// Accumulated base64-encoded bytes. We keep them encoded until FileEnd
    /// arrives, then decode all at once.
    data: std.ArrayListUnmanaged(u8) = .{},

    pub fn create(alloc: Allocator, meta: Meta) !*Loading {
        const self = try alloc.create(Loading);
        self.* = .{ .meta = meta };
        return self;
    }

    pub fn destroy(self: *Loading, alloc: Allocator) void {
        self.data.deinit(alloc);
        alloc.destroy(self);
    }

    /// Append more base64-encoded data. Rejects payloads that exceed max_bytes.
    pub fn appendChunk(self: *Loading, alloc: Allocator, chunk: []const u8) !void {
        if (self.data.items.len + chunk.len > max_bytes) {
            return error.InvalidData;
        }
        try self.data.appendSlice(alloc, chunk);
    }
};

/// Decode the accumulated base64 payload, then transcode into a Kitty
/// graphics command and execute it against the terminal. `encoded` is
/// base64-encoded bytes (caller retains ownership).
pub fn dispatch(
    alloc: Allocator,
    terminal: *Terminal,
    meta: Meta,
    encoded: []const u8,
) !void {
    if (comptime !build_options.kitty_graphics) return;

    // iTerm2's `inline=0` means "save the file to disk on the client"; we
    // don't implement the download side of the protocol, so drop it on the
    // floor rather than rendering it as if `inline=1`.
    if (!meta.inline_) {
        log.debug("iTerm2 File=inline=0 received; download mode not supported", .{});
        return;
    }

    if (encoded.len == 0) return;
    if (encoded.len > max_bytes) return error.InvalidData;

    // Decode base64 into a fresh buffer sized exactly to the decoded length.
    const max_decoded = simd.base64.maxLen(encoded);
    var scratch = try alloc.alloc(u8, max_decoded);
    const decoded = simd.base64.decode(encoded, scratch) catch |err| {
        alloc.free(scratch);
        log.warn("failed to decode iTerm2 base64 payload: {}", .{err});
        return error.InvalidData;
    };
    if (decoded.len == 0) {
        alloc.free(scratch);
        return;
    }

    // Shrink the scratch buffer to exact decoded size. After this point,
    // `scratch` is the canonical payload buffer and is handed off to the
    // format-specific dispatcher, which takes ownership.
    if (alloc.resize(scratch, decoded.len)) {
        scratch = scratch[0..decoded.len];
    } else {
        const shrunk = alloc.alloc(u8, decoded.len) catch {
            // If we can't shrink we just keep the oversized buffer.
            return dispatchDecoded(alloc, terminal, meta, scratch[0..decoded.len], scratch);
        };
        @memcpy(shrunk, scratch[0..decoded.len]);
        alloc.free(scratch);
        scratch = shrunk;
    }

    try dispatchDecoded(alloc, terminal, meta, scratch, scratch);
}

/// Sniffs the format of the decoded payload and routes to the appropriate
/// format handler. `payload` is the usable byte slice; `owned_buf` is the
/// underlying allocation to free (may be the same slice, or larger if we
/// couldn't shrink). On return `owned_buf` has been freed or transferred.
fn dispatchDecoded(
    alloc: Allocator,
    terminal: *Terminal,
    meta: Meta,
    payload: []u8,
    owned_buf: []u8,
) !void {
    if (isPng(payload)) {
        // PNG: hand the bytes directly to the Kitty pipeline as format=png.
        try dispatchPng(alloc, terminal, meta, owned_buf);
        return;
    }
    if (isJpeg(payload)) {
        defer alloc.free(owned_buf);
        try dispatchJpeg(alloc, terminal, meta, payload);
        return;
    }

    alloc.free(owned_buf);
    log.warn("iTerm2 image: unsupported format (not PNG or JPEG)", .{});
    return error.UnsupportedFormat;
}

fn isPng(data: []const u8) bool {
    return data.len >= 8 and std.mem.eql(
        u8,
        data[0..8],
        &.{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A },
    );
}

fn isJpeg(data: []const u8) bool {
    return data.len >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF;
}

/// Dispatch a PNG payload through the Kitty pipeline. The Kitty pipeline
/// itself decodes PNG via wuffs, so we hand it the raw PNG bytes with
/// format=png. Takes ownership of `png_bytes` (freed via cmd.deinit).
fn dispatchPng(
    alloc: Allocator,
    terminal: *Terminal,
    meta: Meta,
    png_bytes: []const u8,
) !void {
    // Extract PNG dimensions from the IHDR chunk so we can fit-within-box
    // when preserveAspectRatio=1 with both width and height given.
    const dims = pngDims(png_bytes);

    var cmd: kitty_command.Command = .{
        .control = .{
            .transmit_and_display = .{
                .transmission = .{
                    .format = .png,
                    .medium = .direct,
                    .more_chunks = false,
                },
                .display = displayFromMeta(meta, terminal, dims),
            },
        },
        .quiet = .failures,
        .data = png_bytes,
    };
    defer cmd.deinit(alloc);

    _ = kitty_exec.execute(alloc, terminal, &cmd);
}

/// Read PNG image dimensions from the IHDR chunk. PNG layout:
///   [0..8]   signature
///   [8..12]  IHDR length (always 13)
///   [12..16] chunk type "IHDR"
///   [16..20] width  (big-endian u32)
///   [20..24] height (big-endian u32)
/// Returns null if the bytes aren't a valid PNG with an IHDR chunk at offset 8.
fn pngDims(data: []const u8) ?ImageDims {
    if (data.len < 24) return null;
    if (!isPng(data)) return null;
    if (!std.mem.eql(u8, data[12..16], "IHDR")) return null;
    const w = std.mem.readInt(u32, data[16..20], .big);
    const h = std.mem.readInt(u32, data[20..24], .big);
    if (w == 0 or h == 0) return null;
    return .{ .width = w, .height = h };
}

const ImageDims = struct {
    width: u32,
    height: u32,
};

/// Dispatch a JPEG payload. Since Kitty doesn't natively support JPEG,
/// decode to RGBA first via wuffs, then submit as format=rgba.
fn dispatchJpeg(
    alloc: Allocator,
    terminal: *Terminal,
    meta: Meta,
    jpeg_bytes: []const u8,
) !void {
    const decoded = wuffs.jpeg.decode(alloc, jpeg_bytes) catch |err| switch (err) {
        error.WuffsError => return error.InvalidData,
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow => return error.InvalidData,
    };
    errdefer alloc.free(decoded.data);

    const rgba_bytes = try alloc.dupe(u8, decoded.data);
    alloc.free(decoded.data);
    errdefer alloc.free(rgba_bytes);

    var cmd: kitty_command.Command = .{
        .control = .{
            .transmit_and_display = .{
                .transmission = .{
                    .format = .rgba,
                    .medium = .direct,
                    .width = @intCast(decoded.width),
                    .height = @intCast(decoded.height),
                    .more_chunks = false,
                },
                .display = displayFromMeta(meta, terminal, .{
                    .width = @intCast(decoded.width),
                    .height = @intCast(decoded.height),
                }),
            },
        },
        .quiet = .failures,
        .data = rgba_bytes,
    };
    defer cmd.deinit(alloc);

    _ = kitty_exec.execute(alloc, terminal, &cmd);
}

/// Build a Kitty Display struct from iTerm2 meta. We translate:
///   iTerm2 width=N cells      -> Kitty columns = N
///   iTerm2 height=N cells     -> Kitty rows = N
///   iTerm2 width=Npx          -> Kitty columns = ceil(N / cell_pixel_width)
///   iTerm2 height=Npx         -> Kitty rows    = ceil(N / cell_pixel_height)
///   iTerm2 width=N%           -> Kitty columns = N% of terminal cols
///   iTerm2 height=N%          -> Kitty rows    = N% of terminal rows
///   iTerm2 doNotMoveCursor=1  -> Kitty cursor_movement = .none
///
/// preserveAspectRatio: iTerm2 defaults to preserving aspect ratio. Kitty's
/// placement has no direct "fit within box" mode: if both columns and rows
/// are set, it stretches to exactly that grid; if only one is set, it
/// derives the other from the image's aspect ratio.
///
/// To emulate iTerm2's fit-within-box with preservation, when both dims are
/// supplied and we know the image's pixel dimensions, we pick the
/// more-constraining axis (the one that yields a smaller result when
/// preserving aspect) and clear the other. Without image dims we fall back
/// to keeping the column constraint, which is the common case for terminal
/// image output.
///
/// Do NOT map pixel iTerm2 dims onto Kitty's Display.width / Display.height —
/// those fields are source-rectangle crops, not display sizing.
fn displayFromMeta(
    meta: Meta,
    terminal: *const Terminal,
    image_dims: ?ImageDims,
) kitty_command.Display {
    var d: kitty_command.Display = .{};

    const cell_w: u32 = if (terminal.cols > 0) @max(1, terminal.width_px / terminal.cols) else 1;
    const cell_h: u32 = if (terminal.rows > 0) @max(1, terminal.height_px / terminal.rows) else 1;

    d.columns = dimToCells(meta.width, terminal.cols, cell_w);
    d.rows = dimToCells(meta.height, terminal.rows, cell_h);

    // Resolve preserveAspectRatio with both dims given.
    if (meta.preserve_aspect_ratio and d.columns > 0 and d.rows > 0) {
        if (image_dims) |img| {
            // Target box in pixels. Image aspect = img.width / img.height.
            // If image_width * target_box_height_px > image_height * target_box_width_px,
            // the image is wider than the box → width-constrained (keep cols, drop rows).
            // Else the image is taller than the box → height-constrained.
            const target_w_px: u64 = @as(u64, d.columns) * cell_w;
            const target_h_px: u64 = @as(u64, d.rows) * cell_h;
            const img_w: u64 = img.width;
            const img_h: u64 = img.height;
            if (img_w * target_h_px > img_h * target_w_px) {
                d.rows = 0; // width-constrained
            } else {
                d.columns = 0; // height-constrained
            }
        } else {
            // No image dims available — fall back to width-constrained.
            d.rows = 0;
        }
    }

    if (meta.do_not_move_cursor) {
        d.cursor_movement = .none;
    }

    return d;
}

fn dimToCells(dim: Meta.Dim, axis_cells: anytype, cell_pixels: u32) u32 {
    return switch (dim) {
        .auto => 0,
        .cells => |n| n,
        .pixels => |n| if (cell_pixels == 0) 0 else (n + cell_pixels - 1) / cell_pixels,
        .percent => |pct| blk: {
            const axis: u64 = @intCast(axis_cells);
            const p: u64 = @intCast(pct);
            break :blk @intCast((axis * p + 99) / 100);
        },
    };
}

// ---------------------------------------------------------------------------
// Tests

test "Meta.parse: imgcat default args" {
    const m = Meta.parse("inline=1;size=4096;preserveAspectRatio=1");
    try std.testing.expect(m.inline_);
    try std.testing.expectEqual(@as(?u64, 4096), m.size);
    try std.testing.expect(m.preserve_aspect_ratio);
    try std.testing.expect(!m.do_not_move_cursor);
}

test "Meta.parse: width/height variants" {
    {
        const m = Meta.parse("width=42;height=10");
        try std.testing.expectEqual(@as(u32, 42), m.width.cells);
        try std.testing.expectEqual(@as(u32, 10), m.height.cells);
    }
    {
        const m = Meta.parse("width=200px;height=100px");
        try std.testing.expectEqual(@as(u32, 200), m.width.pixels);
        try std.testing.expectEqual(@as(u32, 100), m.height.pixels);
    }
    {
        const m = Meta.parse("width=50%;height=25%");
        try std.testing.expectEqual(@as(u32, 50), m.width.percent);
        try std.testing.expectEqual(@as(u32, 25), m.height.percent);
    }
    {
        const m = Meta.parse("width=auto");
        try std.testing.expect(m.width == .auto);
    }
}

test "Meta.parse: doNotMoveCursor" {
    const m = Meta.parse("inline=1;doNotMoveCursor=1");
    try std.testing.expect(m.do_not_move_cursor);
}

test "Meta.parse: preserveAspectRatio=0" {
    const m = Meta.parse("preserveAspectRatio=0");
    try std.testing.expect(!m.preserve_aspect_ratio);
}

test "Meta.parse: ignores unknown keys" {
    const m = Meta.parse("inline=1;type=image/png;name=Zm9vLnBuZw==");
    try std.testing.expect(m.inline_);
}

test "isPng/isJpeg sniffing" {
    const png_magic = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0 };
    const jpeg_magic = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 };
    try std.testing.expect(isPng(&png_magic));
    try std.testing.expect(!isJpeg(&png_magic));
    try std.testing.expect(isJpeg(&jpeg_magic));
    try std.testing.expect(!isPng(&jpeg_magic));
    try std.testing.expect(!isPng(""));
    try std.testing.expect(!isJpeg(""));
}

test "dimToCells: cells passthrough" {
    try std.testing.expectEqual(@as(u32, 20), dimToCells(.{ .cells = 20 }, @as(u16, 80), 10));
    try std.testing.expectEqual(@as(u32, 0), dimToCells(.auto, @as(u16, 80), 10));
}

test "dimToCells: pixels round up to cells" {
    // 199 px / 10 px-per-cell => 20 cells (ceil)
    try std.testing.expectEqual(@as(u32, 20), dimToCells(.{ .pixels = 199 }, @as(u16, 80), 10));
    // 200 px / 10 px-per-cell => 20 cells exactly
    try std.testing.expectEqual(@as(u32, 20), dimToCells(.{ .pixels = 200 }, @as(u16, 80), 10));
    // 201 px / 10 px-per-cell => 21 cells (ceil)
    try std.testing.expectEqual(@as(u32, 21), dimToCells(.{ .pixels = 201 }, @as(u16, 80), 10));
}

test "dimToCells: percent of axis" {
    // 50% of 80 cols => 40 cols
    try std.testing.expectEqual(@as(u32, 40), dimToCells(.{ .percent = 50 }, @as(u16, 80), 10));
    // 25% of 80 cols => 20 cols
    try std.testing.expectEqual(@as(u32, 20), dimToCells(.{ .percent = 25 }, @as(u16, 80), 10));
}

test "pngDims: valid PNG magic + IHDR" {
    // Synthetic minimal PNG: signature + length + IHDR + width + height
    var buf: [24]u8 = undefined;
    @memcpy(buf[0..8], &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });
    @memcpy(buf[8..12], &[_]u8{ 0, 0, 0, 13 }); // length
    @memcpy(buf[12..16], "IHDR");
    std.mem.writeInt(u32, buf[16..20], 1024, .big);
    std.mem.writeInt(u32, buf[20..24], 512, .big);

    const dims = pngDims(&buf).?;
    try std.testing.expectEqual(@as(u32, 1024), dims.width);
    try std.testing.expectEqual(@as(u32, 512), dims.height);
}

test "pngDims: rejects non-PNG" {
    try std.testing.expect(pngDims("not a png") == null);
    try std.testing.expect(pngDims("") == null);
}

test "displayFromMeta: preserveAspectRatio with wide image keeps columns" {
    // 40x40 terminal grid, 10x20 px cells (realistic-ish aspect).
    var t: Terminal = try .init(std.testing.allocator, .{ .cols = 40, .rows = 40 });
    defer t.deinit(std.testing.allocator);
    t.width_px = 400;
    t.height_px = 800;

    var m: Meta = .{ .inline_ = true };
    m.width = .{ .cells = 20 };
    m.height = .{ .cells = 20 };
    m.preserve_aspect_ratio = true;

    // 1000x200 image — much wider than the 20x20 cell box (200x400 px).
    // Width-constrained: keep columns, drop rows.
    const d = displayFromMeta(m, &t, .{ .width = 1000, .height = 200 });
    try std.testing.expectEqual(@as(u32, 20), d.columns);
    try std.testing.expectEqual(@as(u32, 0), d.rows);
}

test "displayFromMeta: preserveAspectRatio with tall image keeps rows" {
    var t: Terminal = try .init(std.testing.allocator, .{ .cols = 40, .rows = 40 });
    defer t.deinit(std.testing.allocator);
    t.width_px = 400;
    t.height_px = 800;

    var m: Meta = .{ .inline_ = true };
    m.width = .{ .cells = 20 };
    m.height = .{ .cells = 20 };
    m.preserve_aspect_ratio = true;

    // 200x1000 image — much taller than the box. Height-constrained:
    // drop columns, keep rows.
    const d = displayFromMeta(m, &t, .{ .width = 200, .height = 1000 });
    try std.testing.expectEqual(@as(u32, 0), d.columns);
    try std.testing.expectEqual(@as(u32, 20), d.rows);
}

test "displayFromMeta: preserveAspectRatio=0 uses both dims (stretch)" {
    var t: Terminal = try .init(std.testing.allocator, .{ .cols = 40, .rows = 40 });
    defer t.deinit(std.testing.allocator);
    t.width_px = 400;
    t.height_px = 800;

    var m: Meta = .{ .inline_ = true };
    m.width = .{ .cells = 20 };
    m.height = .{ .cells = 10 };
    m.preserve_aspect_ratio = false;

    const d = displayFromMeta(m, &t, .{ .width = 1000, .height = 1000 });
    try std.testing.expectEqual(@as(u32, 20), d.columns);
    try std.testing.expectEqual(@as(u32, 10), d.rows);
}

test "displayFromMeta: single dim passthrough" {
    var t: Terminal = try .init(std.testing.allocator, .{ .cols = 40, .rows = 40 });
    defer t.deinit(std.testing.allocator);
    t.width_px = 400;
    t.height_px = 800;

    var m: Meta = .{ .inline_ = true };
    m.width = .{ .cells = 20 };
    m.preserve_aspect_ratio = true;

    // Only width set — no box-fit logic kicks in; Kitty handles aspect.
    const d = displayFromMeta(m, &t, .{ .width = 1000, .height = 100 });
    try std.testing.expectEqual(@as(u32, 20), d.columns);
    try std.testing.expectEqual(@as(u32, 0), d.rows);
}
