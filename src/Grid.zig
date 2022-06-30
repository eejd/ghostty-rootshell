//! Represents a single terminal grid.
const Grid = @This();

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Atlas = @import("Atlas.zig");
const font = @import("font/font.zig");
const terminal = @import("terminal/main.zig");
const Terminal = terminal.Terminal;
const gl = @import("opengl.zig");
const gb = @import("gb_math.zig");
const trace = @import("tracy/tracy.zig").trace;

const log = std.log.scoped(.grid);

alloc: std.mem.Allocator,

/// Current dimensions for this grid.
size: GridSize,

/// Current cell dimensions for this grid.
cell_size: CellSize,

/// The current set of cells to render.
cells: std.ArrayListUnmanaged(GPUCell),

/// Shader program for cell rendering.
program: gl.Program,
vao: gl.VertexArray,
ebo: gl.Buffer,
vbo: gl.Buffer,
texture: gl.Texture,

/// The font atlas.
font_atlas: font.Family,
atlas_dirty: bool,

/// Whether the cursor is visible or not. This is used to control cursor
/// blinking.
cursor_visible: bool,
cursor_style: CursorStyle,

/// Default foreground color
foreground: terminal.color.RGB,

/// Default background color
background: terminal.color.RGB,

/// Available cursor styles for drawing. The values represents the mode value
/// in the shader.
pub const CursorStyle = enum(u8) {
    box = 3,
    box_hollow = 4,
    bar = 5,

    /// Create a cursor style from the terminal style request.
    pub fn fromTerminal(style: terminal.CursorStyle) ?CursorStyle {
        return switch (style) {
            .blinking_block, .steady_block => .box,
            .blinking_bar, .steady_bar => .bar,
            .blinking_underline, .steady_underline => null, // TODO
            .default => .box,
            else => null,
        };
    }
};

/// The raw structure that maps directly to the buffer sent to the vertex shader.
const GPUCell = struct {
    /// vec2 grid_coord
    grid_col: u16,
    grid_row: u16,

    /// vec2 glyph_pos
    glyph_x: u32 = 0,
    glyph_y: u32 = 0,

    /// vec2 glyph_size
    glyph_width: u32 = 0,
    glyph_height: u32 = 0,

    /// vec2 glyph_size
    glyph_offset_x: i32 = 0,
    glyph_offset_y: i32 = 0,

    /// vec4 fg_color_in
    fg_r: u8,
    fg_g: u8,
    fg_b: u8,
    fg_a: u8,

    /// vec4 bg_color_in
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    bg_a: u8,

    /// uint mode
    mode: u8,
};

pub fn init(alloc: Allocator) !Grid {
    // Initialize our font atlas. We will initially populate the
    // font atlas with all the visible ASCII characters since they are common.
    var atlas = try Atlas.init(alloc, 512);
    errdefer atlas.deinit(alloc);
    var fam = try font.Family.init(atlas);
    errdefer fam.deinit(alloc);
    try fam.loadFaceFromMemory(.regular, face_ttf, 32);
    try fam.loadFaceFromMemory(.bold, face_bold_ttf, 32);

    // Load all visible ASCII characters and build our cell width based on
    // the widest character that we see.
    const cell_width: f32 = cell_width: {
        var cell_width: f32 = 0;
        var i: u8 = 32;
        while (i <= 126) : (i += 1) {
            const glyph = try fam.addGlyph(alloc, i, .regular);
            if (glyph.advance_x > cell_width) {
                cell_width = @ceil(glyph.advance_x);
            }
        }

        break :cell_width cell_width;
    };

    // The cell height is the vertical height required to render underscore
    // '_' which should live at the bottom of a cell.
    const cell_height: f32 = cell_height: {
        // This is the height reported by the font face
        const face_height: i32 = fam.regular.?.unitsToPxY(fam.regular.?.ft_face.*.height);

        // Determine the height of the underscore char
        const glyph = fam.getGlyph('_', .regular).?;
        var res: i32 = fam.regular.?.unitsToPxY(fam.regular.?.ft_face.*.ascender);
        res -= glyph.offset_y;
        res += @intCast(i32, glyph.height);

        // We take whatever is larger to account for some fonts that
        // put the underscore outside f the rectangle.
        if (res < face_height) res = face_height;

        break :cell_height @intToFloat(f32, res);
    };
    const cell_baseline = cell_height - @intToFloat(
        f32,
        fam.regular.?.unitsToPxY(fam.regular.?.ft_face.*.ascender),
    );
    log.debug("cell dimensions w={d} h={d} baseline={d}", .{ cell_width, cell_height, cell_baseline });

    // Create our shader
    const program = try gl.Program.createVF(
        @embedFile("../shaders/cell.v.glsl"),
        @embedFile("../shaders/cell.f.glsl"),
    );

    // Set our cell dimensions
    const pbind = try program.use();
    defer pbind.unbind();
    try program.setUniform("cell_size", @Vector(2, f32){ cell_width, cell_height });
    try program.setUniform("glyph_baseline", cell_baseline);

    // Setup our VAO
    const vao = try gl.VertexArray.create();
    errdefer vao.destroy();
    try vao.bind();
    defer gl.VertexArray.unbind() catch null;

    // Element buffer (EBO)
    const ebo = try gl.Buffer.create();
    errdefer ebo.destroy();
    var ebobind = try ebo.bind(.ElementArrayBuffer);
    defer ebobind.unbind();
    try ebobind.setData([6]u8{
        0, 1, 3, // Top-left triangle
        1, 2, 3, // Bottom-right triangle
    }, .StaticDraw);

    // Vertex buffer (VBO)
    const vbo = try gl.Buffer.create();
    errdefer vbo.destroy();
    var vbobind = try vbo.bind(.ArrayBuffer);
    defer vbobind.unbind();
    var offset: usize = 0;
    try vbobind.attributeAdvanced(0, 2, gl.c.GL_UNSIGNED_SHORT, false, @sizeOf(GPUCell), offset);
    offset += 2 * @sizeOf(u16);
    try vbobind.attributeAdvanced(1, 2, gl.c.GL_UNSIGNED_INT, false, @sizeOf(GPUCell), offset);
    offset += 2 * @sizeOf(u32);
    try vbobind.attributeAdvanced(2, 2, gl.c.GL_UNSIGNED_INT, false, @sizeOf(GPUCell), offset);
    offset += 2 * @sizeOf(u32);
    try vbobind.attributeAdvanced(3, 2, gl.c.GL_INT, false, @sizeOf(GPUCell), offset);
    offset += 2 * @sizeOf(i32);
    try vbobind.attributeAdvanced(4, 4, gl.c.GL_UNSIGNED_BYTE, false, @sizeOf(GPUCell), offset);
    offset += 4 * @sizeOf(u8);
    try vbobind.attributeAdvanced(5, 4, gl.c.GL_UNSIGNED_BYTE, false, @sizeOf(GPUCell), offset);
    offset += 4 * @sizeOf(u8);
    try vbobind.attributeIAdvanced(6, 1, gl.c.GL_UNSIGNED_BYTE, @sizeOf(GPUCell), offset);
    try vbobind.enableAttribArray(0);
    try vbobind.enableAttribArray(1);
    try vbobind.enableAttribArray(2);
    try vbobind.enableAttribArray(3);
    try vbobind.enableAttribArray(4);
    try vbobind.enableAttribArray(5);
    try vbobind.enableAttribArray(6);
    try vbobind.attributeDivisor(0, 1);
    try vbobind.attributeDivisor(1, 1);
    try vbobind.attributeDivisor(2, 1);
    try vbobind.attributeDivisor(3, 1);
    try vbobind.attributeDivisor(4, 1);
    try vbobind.attributeDivisor(5, 1);
    try vbobind.attributeDivisor(6, 1);

    // Build our texture
    const tex = try gl.Texture.create();
    errdefer tex.destroy();
    const texbind = try tex.bind(.@"2D");
    try texbind.parameter(.WrapS, gl.c.GL_CLAMP_TO_EDGE);
    try texbind.parameter(.WrapT, gl.c.GL_CLAMP_TO_EDGE);
    try texbind.parameter(.MinFilter, gl.c.GL_LINEAR);
    try texbind.parameter(.MagFilter, gl.c.GL_LINEAR);
    try texbind.image2D(
        0,
        .Red,
        @intCast(c_int, atlas.size),
        @intCast(c_int, atlas.size),
        0,
        .Red,
        .UnsignedByte,
        atlas.data.ptr,
    );

    return Grid{
        .alloc = alloc,
        .cells = .{},
        .cell_size = .{ .width = cell_width, .height = cell_height },
        .size = .{ .rows = 0, .columns = 0 },
        .program = program,
        .vao = vao,
        .ebo = ebo,
        .vbo = vbo,
        .texture = tex,
        .font_atlas = fam,
        .atlas_dirty = false,
        .cursor_visible = true,
        .cursor_style = .box,
        .background = .{ .r = 0, .g = 0, .b = 0 },
        .foreground = .{ .r = 255, .g = 255, .b = 255 },
    };
}

pub fn deinit(self: *Grid) void {
    self.font_atlas.atlas.deinit(self.alloc);
    self.font_atlas.deinit(self.alloc);
    self.texture.destroy();
    self.vbo.destroy();
    self.ebo.destroy();
    self.vao.destroy();
    self.program.destroy();
    self.cells.deinit(self.alloc);
    self.* = undefined;
}

/// updateCells updates our GPU cells from the current terminal view.
/// The updated cells will take effect on the next render.
pub fn updateCells(self: *Grid, term: Terminal) !void {
    const t = trace(@src());
    defer t.end();

    // For now, we just ensure that we have enough cells for all the lines
    // we have plus a full width. This is very likely too much but its
    // the probably close enough while guaranteeing no more allocations.
    self.cells.clearRetainingCapacity();
    try self.cells.ensureTotalCapacity(
        self.alloc,

        // * 3 for background modes and cursor and underlines
        // + 1 for cursor
        (term.screen.rows * term.screen.cols * 3) + 1,
    );

    // Build each cell
    var rowIter = term.screen.rowIterator();
    var y: usize = 0;
    while (rowIter.next()) |line| {
        defer y += 1;

        for (line) |cell, x| {
            // The colors for the cell.
            const colors: struct {
                /// Background is optional because in un-inverted mode
                /// it may just be equivalent to the default background in
                /// which case we do nothing to save on GPU render time.
                bg: ?terminal.color.RGB,

                /// Fg is always set to some color, though we may not render
                /// any fg if the cell is empty or has no attributes like
                /// underline.
                fg: terminal.color.RGB,
            } = if (cell.attrs.inverse == 0) .{
                // In normal mode, background and fg match the cell. We
                // un-optionalize the fg by defaulting to our fg color.
                .bg = cell.bg,
                .fg = cell.fg orelse self.foreground,
            } else .{
                // In inverted mode, the background MUST be set to something
                // (is never null) so it is either the fg or default fg. The
                // fg is either the bg or default background.
                .bg = cell.fg orelse self.foreground,
                .fg = cell.bg orelse self.background,
            };

            // If the cell has a background, we always draw it.
            if (colors.bg) |rgb| {
                self.cells.appendAssumeCapacity(.{
                    .mode = 1,
                    .grid_col = @intCast(u16, x),
                    .grid_row = @intCast(u16, y),
                    .glyph_x = 0,
                    .glyph_y = 0,
                    .glyph_width = 0,
                    .glyph_height = 0,
                    .glyph_offset_x = 0,
                    .glyph_offset_y = 0,
                    .fg_r = 0,
                    .fg_g = 0,
                    .fg_b = 0,
                    .fg_a = 0,
                    .bg_r = rgb.r,
                    .bg_g = rgb.g,
                    .bg_b = rgb.b,
                    .bg_a = 0xFF,
                });
            }

            // If the cell is empty then we draw nothing in the box.
            if (!cell.empty()) {
                // Determine our glyph styling
                const style: font.Style = if (cell.attrs.bold == 1)
                    .bold
                else
                    .regular;

                // Get our glyph
                // TODO: if we add a glyph, I think we need to rerender the texture.
                const glyph = if (self.font_atlas.getGlyph(cell.char, style)) |glyph|
                    glyph
                else glyph: {
                    self.atlas_dirty = true;
                    break :glyph try self.font_atlas.addGlyph(self.alloc, cell.char, style);
                };

                self.cells.appendAssumeCapacity(.{
                    .mode = 2,
                    .grid_col = @intCast(u16, x),
                    .grid_row = @intCast(u16, y),
                    .glyph_x = glyph.atlas_x,
                    .glyph_y = glyph.atlas_y,
                    .glyph_width = glyph.width,
                    .glyph_height = glyph.height,
                    .glyph_offset_x = glyph.offset_x,
                    .glyph_offset_y = glyph.offset_y,
                    .fg_r = colors.fg.r,
                    .fg_g = colors.fg.g,
                    .fg_b = colors.fg.b,
                    .fg_a = 255,
                    .bg_r = 0,
                    .bg_g = 0,
                    .bg_b = 0,
                    .bg_a = 0,
                });
            }

            if (cell.attrs.underline == 1) {
                self.cells.appendAssumeCapacity(.{
                    .mode = 6, // underline
                    .grid_col = @intCast(u16, x),
                    .grid_row = @intCast(u16, y),
                    .glyph_x = 0,
                    .glyph_y = 0,
                    .glyph_width = 0,
                    .glyph_height = 0,
                    .glyph_offset_x = 0,
                    .glyph_offset_y = 0,
                    .fg_r = colors.fg.r,
                    .fg_g = colors.fg.g,
                    .fg_b = colors.fg.b,
                    .fg_a = 255,
                    .bg_r = 0,
                    .bg_g = 0,
                    .bg_b = 0,
                    .bg_a = 0,
                });
            }
        }
    }

    // Draw the cursor
    if (self.cursor_visible) {
        self.cells.appendAssumeCapacity(.{
            .mode = @enumToInt(self.cursor_style),
            .grid_col = @intCast(u16, term.cursor.x),
            .grid_row = @intCast(u16, term.cursor.y),
            .fg_r = 0,
            .fg_g = 0,
            .fg_b = 0,
            .fg_a = 0,
            .bg_r = 0xFF,
            .bg_g = 0xFF,
            .bg_b = 0xFF,
            .bg_a = 255,
        });
    }
}

/// Set the screen size for rendering. This will update the projection
/// used for the shader so that the scaling of the grid is correct.
pub fn setScreenSize(self: *Grid, dim: ScreenSize) !void {
    // Create a 2D orthographic projection matrix with the full width/height.
    var projection: gb.gbMat4 = undefined;
    gb.gb_mat4_ortho2d(
        &projection,
        0,
        @intToFloat(f32, dim.width),
        @intToFloat(f32, dim.height),
        0,
    );

    // Update the projection uniform within our shader
    const bind = try self.program.use();
    defer bind.unbind();
    try self.program.setUniform("projection", projection);

    // Recalculate the rows/columns.
    self.size.update(dim, self.cell_size);

    log.debug("screen size screen={} grid={}, cell={}", .{ dim, self.size, self.cell_size });
}

/// Updates the font texture atlas if it is dirty.
pub fn flushAtlas(self: *Grid) !void {
    if (!self.atlas_dirty) return;

    var texbind = try self.texture.bind(.@"2D");
    defer texbind.unbind();
    try texbind.subImage2D(
        0,
        0,
        0,
        @intCast(c_int, self.font_atlas.atlas.size),
        @intCast(c_int, self.font_atlas.atlas.size),
        .Red,
        .UnsignedByte,
        self.font_atlas.atlas.data.ptr,
    );

    self.atlas_dirty = false;
}

pub fn render(self: Grid) !void {
    const t = trace(@src());
    defer t.end();

    // If we have no cells to render, then we render nothing.
    if (self.cells.items.len == 0) return;

    const pbind = try self.program.use();
    defer pbind.unbind();

    // Setup our VAO
    try self.vao.bind();
    defer gl.VertexArray.unbind() catch null;

    // Bind EBO
    var ebobind = try self.ebo.bind(.ElementArrayBuffer);
    defer ebobind.unbind();

    // Bind VBO and set data
    var binding = try self.vbo.bind(.ArrayBuffer);
    defer binding.unbind();
    try binding.setData(self.cells.items, .StaticDraw);

    // Bind our texture
    try gl.Texture.active(gl.c.GL_TEXTURE0);
    var texbind = try self.texture.bind(.@"2D");
    defer texbind.unbind();

    try gl.drawElementsInstanced(
        gl.c.GL_TRIANGLES,
        6,
        gl.c.GL_UNSIGNED_BYTE,
        self.cells.items.len,
    );
}

/// The dimensions of a single "cell" in the terminal grid.
///
/// The dimensions are dependent on the current loaded set of font glyphs.
/// We calculate the width based on the widest character and the height based
/// on the height requirement for an underscore (the "lowest" -- visually --
/// character).
///
/// The units for the width and height are in world space. They have to
/// be normalized using the screen projection.
///
/// TODO(mitchellh): we should recalculate cell dimensions when new glyphs
/// are loaded.
const CellSize = struct {
    width: f32,
    height: f32,
};

/// The dimensions of the screen that the grid is rendered to. This is the
/// terminal screen, so it is likely a subset of the window size. The dimensions
/// should be in pixels.
const ScreenSize = struct {
    width: u32,
    height: u32,
};

/// The dimensions of the grid itself, in rows/columns units.
const GridSize = struct {
    const Unit = u32;

    columns: Unit = 0,
    rows: Unit = 0,

    /// Update the columns/rows for the grid based on the given screen and
    /// cell size.
    fn update(self: *GridSize, screen: ScreenSize, cell: CellSize) void {
        self.columns = @floatToInt(Unit, @intToFloat(f32, screen.width) / cell.width);
        self.rows = @floatToInt(Unit, @intToFloat(f32, screen.height) / cell.height);
    }
};

test "GridSize update exact" {
    var grid: GridSize = .{};
    grid.update(.{
        .width = 100,
        .height = 40,
    }, .{
        .width = 5,
        .height = 10,
    });

    try testing.expectEqual(@as(GridSize.Unit, 20), grid.columns);
    try testing.expectEqual(@as(GridSize.Unit, 4), grid.rows);
}

test "GridSize update rounding" {
    var grid: GridSize = .{};
    grid.update(.{
        .width = 20,
        .height = 40,
    }, .{
        .width = 6,
        .height = 15,
    });

    try testing.expectEqual(@as(GridSize.Unit, 3), grid.columns);
    try testing.expectEqual(@as(GridSize.Unit, 2), grid.rows);
}

const face_ttf = @embedFile("../fonts/FiraCode-Regular.ttf");
const face_bold_ttf = @embedFile("../fonts/FiraCode-Bold.ttf");
