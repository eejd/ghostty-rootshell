//! This file contains functions for drawing the box drawing characters
//! (https://en.wikipedia.org/wiki/Box-drawing_character) and related
//! characters that are provided by the terminal.
//!
//! The box drawing logic is based off similar logic in Kitty and Foot.
//! The primary drawing code was originally ported directly and slightly
//! modified from Foot (https://codeberg.org/dnkl/foot/). Foot is licensed
//! under the MIT license and is copyright 2019 Daniel Eklöf.
//!
//! The modifications made were primarily around spacing, DPI calculations,
//! and adapting the code to our atlas model. Further, more extensive changes
//! were made, refactoring the line characters to all share a single unified
//! function (draw_lines), as well as many of the fractional block characters
//! which now use draw_block instead of dedicated separate functions.
//!
//! Additional characters from Unicode 16.0 and beyond are original work.
const Box = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const font = @import("../main.zig");
const Sprite = @import("../sprite.zig").Sprite;

const log = std.log.scoped(.box_font);

/// The cell width and height because the boxes are fit perfectly
/// into a cell so that they all properly connect with zero spacing.
width: u32,
height: u32,

/// Base thickness value for lines of the box. This is in pixels. If you
/// want to do any DPI scaling, it is expected to be done earlier.
thickness: u32,

/// The thickness of a line.
const Thickness = enum {
    super_light,
    light,
    heavy,

    /// Calculate the real height of a line based on its thickness
    /// and a base thickness value. The base thickness value is expected
    /// to be in pixels.
    fn height(self: Thickness, base: u32) u32 {
        return switch (self) {
            .super_light => @max(base / 2, 1),
            .light => base,
            .heavy => base * 2,
        };
    }
};

/// Specification of a traditional intersection-style line/box-drawing char,
/// which can have a different style of line from each edge to the center.
const Lines = struct {
    up: Style = .none,
    right: Style = .none,
    down: Style = .none,
    left: Style = .none,

    const Style = enum {
        none,
        light,
        heavy,
        double,
    };
};

/// Specification of a quadrants char, which has each of the
/// 4 quadrants of the character cell either filled or empty.
const Quads = struct {
    tl: bool = false,
    tr: bool = false,
    bl: bool = false,
    br: bool = false,
};

/// Alignment of a figure within a cell
const Alignment = struct {
    horizontal: enum {
        left,
        right,
        center,
    } = .center,

    vertical: enum {
        top,
        bottom,
        middle,
    } = .middle,

    const upper: Alignment = .{ .vertical = .top };
    const lower: Alignment = .{ .vertical = .bottom };
    const left: Alignment = .{ .horizontal = .left };
    const right: Alignment = .{ .horizontal = .right };

    const upper_left: Alignment = .{ .vertical = .top, .horizontal = .left };
    const upper_right: Alignment = .{ .vertical = .top, .horizontal = .right };
    const lower_left: Alignment = .{ .vertical = .bottom, .horizontal = .left };
    const lower_right: Alignment = .{ .vertical = .bottom, .horizontal = .right };

    const top = upper;
    const bottom = lower;
};

// Utility names for common fractions
const one_eighth: f64 = 0.125;
const one_quarter: f64 = 0.25;
const three_eighths: f64 = 0.375;
const half: f64 = 0.5;
const five_eighths: f64 = 0.625;
const three_quarters: f64 = 0.75;
const seven_eighths: f64 = 0.875;

pub fn renderGlyph(
    self: Box,
    alloc: Allocator,
    atlas: *font.Atlas,
    cp: u32,
) !font.Glyph {
    // Create the canvas we'll use to draw
    var canvas = try font.sprite.Canvas.init(alloc, self.width, self.height);
    defer canvas.deinit(alloc);

    // Perform the actual drawing
    try self.draw(alloc, &canvas, cp);

    // Write the drawing to the atlas
    const region = try canvas.writeAtlas(alloc, atlas);

    // Our coordinates start at the BOTTOM for our renderers so we have to
    // specify an offset of the full height because we rendered a full size
    // cell.
    const offset_y = @as(i32, @intCast(self.height));

    return font.Glyph{
        .width = self.width,
        .height = self.height,
        .offset_x = 0,
        .offset_y = offset_y,
        .atlas_x = region.x,
        .atlas_y = region.y,
        .advance_x = @floatFromInt(self.width),
    };
}

/// Returns true if this codepoint should be rendered with the
/// width/height set to unadjusted values.
pub fn unadjustedCodepoint(cp: u32) bool {
    return switch (cp) {
        @intFromEnum(Sprite.cursor_rect),
        @intFromEnum(Sprite.cursor_hollow_rect),
        @intFromEnum(Sprite.cursor_bar),
        => true,

        else => false,
    };
}

fn draw(self: Box, alloc: Allocator, canvas: *font.sprite.Canvas, cp: u32) !void {
    switch (cp) {
        // '─'
        0x2500 => self.draw_lines(canvas, .{ .left = .light, .right = .light }),
        // '━'
        0x2501 => self.draw_lines(canvas, .{ .left = .heavy, .right = .heavy }),
        // '│'
        0x2502 => self.draw_lines(canvas, .{ .up = .light, .down = .light }),
        // '┃'
        0x2503 => self.draw_lines(canvas, .{ .up = .heavy, .down = .heavy }),
        // '┄'
        0x2504 => self.draw_light_triple_dash_horizontal(canvas),
        // '┅'
        0x2505 => self.draw_heavy_triple_dash_horizontal(canvas),
        // '┆'
        0x2506 => self.draw_light_triple_dash_vertical(canvas),
        // '┇'
        0x2507 => self.draw_heavy_triple_dash_vertical(canvas),
        // '┈'
        0x2508 => self.draw_light_quadruple_dash_horizontal(canvas),
        // '┉'
        0x2509 => self.draw_heavy_quadruple_dash_horizontal(canvas),
        // '┊'
        0x250a => self.draw_light_quadruple_dash_vertical(canvas),
        // '┋'
        0x250b => self.draw_heavy_quadruple_dash_vertical(canvas),
        // '┌'
        0x250c => self.draw_lines(canvas, .{ .down = .light, .right = .light }),
        // '┍'
        0x250d => self.draw_lines(canvas, .{ .down = .light, .right = .heavy }),
        // '┎'
        0x250e => self.draw_lines(canvas, .{ .down = .heavy, .right = .light }),
        // '┏'
        0x250f => self.draw_lines(canvas, .{ .down = .heavy, .right = .heavy }),

        // '┐'
        0x2510 => self.draw_lines(canvas, .{ .down = .light, .left = .light }),
        // '┑'
        0x2511 => self.draw_lines(canvas, .{ .down = .light, .left = .heavy }),
        // '┒'
        0x2512 => self.draw_lines(canvas, .{ .down = .heavy, .left = .light }),
        // '┓'
        0x2513 => self.draw_lines(canvas, .{ .down = .heavy, .left = .heavy }),
        // '└'
        0x2514 => self.draw_lines(canvas, .{ .up = .light, .right = .light }),
        // '┕'
        0x2515 => self.draw_lines(canvas, .{ .up = .light, .right = .heavy }),
        // '┖'
        0x2516 => self.draw_lines(canvas, .{ .up = .heavy, .right = .light }),
        // '┗'
        0x2517 => self.draw_lines(canvas, .{ .up = .heavy, .right = .heavy }),
        // '┘'
        0x2518 => self.draw_lines(canvas, .{ .up = .light, .left = .light }),
        // '┙'
        0x2519 => self.draw_lines(canvas, .{ .up = .light, .left = .heavy }),
        // '┚'
        0x251a => self.draw_lines(canvas, .{ .up = .heavy, .left = .light }),
        // '┛'
        0x251b => self.draw_lines(canvas, .{ .up = .heavy, .left = .heavy }),
        // '├'
        0x251c => self.draw_lines(canvas, .{ .up = .light, .down = .light, .right = .light }),
        // '┝'
        0x251d => self.draw_lines(canvas, .{ .up = .light, .down = .light, .right = .heavy }),
        // '┞'
        0x251e => self.draw_lines(canvas, .{ .up = .heavy, .right = .light, .down = .light }),
        // '┟'
        0x251f => self.draw_lines(canvas, .{ .down = .heavy, .right = .light, .up = .light }),

        // '┠'
        0x2520 => self.draw_lines(canvas, .{ .up = .heavy, .down = .heavy, .right = .light }),
        // '┡'
        0x2521 => self.draw_lines(canvas, .{ .down = .light, .right = .heavy, .up = .heavy }),
        // '┢'
        0x2522 => self.draw_lines(canvas, .{ .up = .light, .right = .heavy, .down = .heavy }),
        // '┣'
        0x2523 => self.draw_lines(canvas, .{ .up = .heavy, .down = .heavy, .right = .heavy }),
        // '┤'
        0x2524 => self.draw_lines(canvas, .{ .up = .light, .down = .light, .left = .light }),
        // '┥'
        0x2525 => self.draw_lines(canvas, .{ .up = .light, .down = .light, .left = .heavy }),
        // '┦'
        0x2526 => self.draw_lines(canvas, .{ .up = .heavy, .left = .light, .down = .light }),
        // '┧'
        0x2527 => self.draw_lines(canvas, .{ .down = .heavy, .left = .light, .up = .light }),
        // '┨'
        0x2528 => self.draw_lines(canvas, .{ .up = .heavy, .down = .heavy, .left = .light }),
        // '┩'
        0x2529 => self.draw_lines(canvas, .{ .down = .light, .left = .heavy, .up = .heavy }),
        // '┪'
        0x252a => self.draw_lines(canvas, .{ .up = .light, .left = .heavy, .down = .heavy }),
        // '┫'
        0x252b => self.draw_lines(canvas, .{ .up = .heavy, .down = .heavy, .left = .heavy }),
        // '┬'
        0x252c => self.draw_lines(canvas, .{ .down = .light, .left = .light, .right = .light }),
        // '┭'
        0x252d => self.draw_lines(canvas, .{ .left = .heavy, .right = .light, .down = .light }),
        // '┮'
        0x252e => self.draw_lines(canvas, .{ .right = .heavy, .left = .light, .down = .light }),
        // '┯'
        0x252f => self.draw_lines(canvas, .{ .down = .light, .left = .heavy, .right = .heavy }),

        // '┰'
        0x2530 => self.draw_lines(canvas, .{ .down = .heavy, .left = .light, .right = .light }),
        // '┱'
        0x2531 => self.draw_lines(canvas, .{ .right = .light, .left = .heavy, .down = .heavy }),
        // '┲'
        0x2532 => self.draw_lines(canvas, .{ .left = .light, .right = .heavy, .down = .heavy }),
        // '┳'
        0x2533 => self.draw_lines(canvas, .{ .down = .heavy, .left = .heavy, .right = .heavy }),
        // '┴'
        0x2534 => self.draw_lines(canvas, .{ .up = .light, .left = .light, .right = .light }),
        // '┵'
        0x2535 => self.draw_lines(canvas, .{ .left = .heavy, .right = .light, .up = .light }),
        // '┶'
        0x2536 => self.draw_lines(canvas, .{ .right = .heavy, .left = .light, .up = .light }),
        // '┷'
        0x2537 => self.draw_lines(canvas, .{ .up = .light, .left = .heavy, .right = .heavy }),
        // '┸'
        0x2538 => self.draw_lines(canvas, .{ .up = .heavy, .left = .light, .right = .light }),
        // '┹'
        0x2539 => self.draw_lines(canvas, .{ .right = .light, .left = .heavy, .up = .heavy }),
        // '┺'
        0x253a => self.draw_lines(canvas, .{ .left = .light, .right = .heavy, .up = .heavy }),
        // '┻'
        0x253b => self.draw_lines(canvas, .{ .up = .heavy, .left = .heavy, .right = .heavy }),
        // '┼'
        0x253c => self.draw_lines(canvas, .{ .up = .light, .down = .light, .left = .light, .right = .light }),
        // '┽'
        0x253d => self.draw_lines(canvas, .{ .left = .heavy, .right = .light, .up = .light, .down = .light }),
        // '┾'
        0x253e => self.draw_lines(canvas, .{ .right = .heavy, .left = .light, .up = .light, .down = .light }),
        // '┿'
        0x253f => self.draw_lines(canvas, .{ .up = .light, .down = .light, .left = .heavy, .right = .heavy }),

        // '╀'
        0x2540 => self.draw_lines(canvas, .{ .up = .heavy, .down = .light, .left = .light, .right = .light }),
        // '╁'
        0x2541 => self.draw_lines(canvas, .{ .down = .heavy, .up = .light, .left = .light, .right = .light }),
        // '╂'
        0x2542 => self.draw_lines(canvas, .{ .up = .heavy, .down = .heavy, .left = .light, .right = .light }),
        // '╃'
        0x2543 => self.draw_lines(canvas, .{ .left = .heavy, .up = .heavy, .right = .light, .down = .light }),
        // '╄'
        0x2544 => self.draw_lines(canvas, .{ .right = .heavy, .up = .heavy, .left = .light, .down = .light }),
        // '╅'
        0x2545 => self.draw_lines(canvas, .{ .left = .heavy, .down = .heavy, .right = .light, .up = .light }),
        // '╆'
        0x2546 => self.draw_lines(canvas, .{ .right = .heavy, .down = .heavy, .left = .light, .up = .light }),
        // '╇'
        0x2547 => self.draw_lines(canvas, .{ .down = .light, .up = .heavy, .left = .heavy, .right = .heavy }),
        // '╈'
        0x2548 => self.draw_lines(canvas, .{ .up = .light, .down = .heavy, .left = .heavy, .right = .heavy }),
        // '╉'
        0x2549 => self.draw_lines(canvas, .{ .right = .light, .left = .heavy, .up = .heavy, .down = .heavy }),
        // '╊'
        0x254a => self.draw_lines(canvas, .{ .left = .light, .right = .heavy, .up = .heavy, .down = .heavy }),
        // '╋'
        0x254b => self.draw_lines(canvas, .{ .up = .heavy, .down = .heavy, .left = .heavy, .right = .heavy }),
        // '╌'
        0x254c => self.draw_light_double_dash_horizontal(canvas),
        // '╍'
        0x254d => self.draw_heavy_double_dash_horizontal(canvas),
        // '╎'
        0x254e => self.draw_light_double_dash_vertical(canvas),
        // '╏'
        0x254f => self.draw_heavy_double_dash_vertical(canvas),

        // '═'
        0x2550 => self.draw_lines(canvas, .{ .left = .double, .right = .double }),
        // '║'
        0x2551 => self.draw_lines(canvas, .{ .up = .double, .down = .double }),
        // '╒'
        0x2552 => self.draw_lines(canvas, .{ .down = .light, .right = .double }),
        // '╓'
        0x2553 => self.draw_lines(canvas, .{ .down = .double, .right = .light }),
        // '╔'
        0x2554 => self.draw_lines(canvas, .{ .down = .double, .right = .double }),
        // '╕'
        0x2555 => self.draw_lines(canvas, .{ .down = .light, .left = .double }),
        // '╖'
        0x2556 => self.draw_lines(canvas, .{ .down = .double, .left = .light }),
        // '╗'
        0x2557 => self.draw_lines(canvas, .{ .down = .double, .left = .double }),
        // '╘'
        0x2558 => self.draw_lines(canvas, .{ .up = .light, .right = .double }),
        // '╙'
        0x2559 => self.draw_lines(canvas, .{ .up = .double, .right = .light }),
        // '╚'
        0x255a => self.draw_lines(canvas, .{ .up = .double, .right = .double }),
        // '╛'
        0x255b => self.draw_lines(canvas, .{ .up = .light, .left = .double }),
        // '╜'
        0x255c => self.draw_lines(canvas, .{ .up = .double, .left = .light }),
        // '╝'
        0x255d => self.draw_lines(canvas, .{ .up = .double, .left = .double }),
        // '╞'
        0x255e => self.draw_lines(canvas, .{ .up = .light, .down = .light, .right = .double }),
        // '╟'
        0x255f => self.draw_lines(canvas, .{ .up = .double, .down = .double, .right = .light }),

        // '╠'
        0x2560 => self.draw_lines(canvas, .{ .up = .double, .down = .double, .right = .double }),
        // '╡'
        0x2561 => self.draw_lines(canvas, .{ .up = .light, .down = .light, .left = .double }),
        // '╢'
        0x2562 => self.draw_lines(canvas, .{ .up = .double, .down = .double, .left = .light }),
        // '╣'
        0x2563 => self.draw_lines(canvas, .{ .up = .double, .down = .double, .left = .double }),
        // '╤'
        0x2564 => self.draw_lines(canvas, .{ .down = .light, .left = .double, .right = .double }),
        // '╥'
        0x2565 => self.draw_lines(canvas, .{ .down = .double, .left = .light, .right = .light }),
        // '╦'
        0x2566 => self.draw_lines(canvas, .{ .down = .double, .left = .double, .right = .double }),
        // '╧'
        0x2567 => self.draw_lines(canvas, .{ .up = .light, .left = .double, .right = .double }),
        // '╨'
        0x2568 => self.draw_lines(canvas, .{ .up = .double, .left = .light, .right = .light }),
        // '╩'
        0x2569 => self.draw_lines(canvas, .{ .up = .double, .left = .double, .right = .double }),
        // '╪'
        0x256a => self.draw_lines(canvas, .{ .up = .light, .down = .light, .left = .double, .right = .double }),
        // '╫'
        0x256b => self.draw_lines(canvas, .{ .up = .double, .down = .double, .left = .light, .right = .light }),
        // '╬'
        0x256c => self.draw_lines(canvas, .{ .up = .double, .down = .double, .left = .double, .right = .double }),
        0x256d...0x2570 => try self.draw_light_arc(alloc, canvas, cp),

        // '╱'
        0x2571 => self.draw_light_diagonal_upper_right_to_lower_left(canvas),
        // '╲'
        0x2572 => self.draw_light_diagonal_upper_left_to_lower_right(canvas),
        // '╳'
        0x2573 => self.draw_light_diagonal_cross(canvas),
        // '╴'
        0x2574 => self.draw_lines(canvas, .{ .left = .light }),
        // '╵'
        0x2575 => self.draw_lines(canvas, .{ .up = .light }),
        // '╶'
        0x2576 => self.draw_lines(canvas, .{ .right = .light }),
        // '╷'
        0x2577 => self.draw_lines(canvas, .{ .down = .light }),
        // '╸'
        0x2578 => self.draw_lines(canvas, .{ .left = .heavy }),
        // '╹'
        0x2579 => self.draw_lines(canvas, .{ .up = .heavy }),
        // '╺'
        0x257a => self.draw_lines(canvas, .{ .right = .heavy }),
        // '╻'
        0x257b => self.draw_lines(canvas, .{ .down = .heavy }),
        // '╼'
        0x257c => self.draw_lines(canvas, .{ .left = .light, .right = .heavy }),
        // '╽'
        0x257d => self.draw_lines(canvas, .{ .up = .light, .down = .heavy }),
        // '╾'
        0x257e => self.draw_lines(canvas, .{ .left = .heavy, .right = .light }),
        // '╿'
        0x257f => self.draw_lines(canvas, .{ .up = .heavy, .down = .light }),

        // '▀' UPPER HALF BLOCK
        0x2580 => self.draw_block(canvas, Alignment.upper, 1, half),
        // '▁' LOWER ONE EIGHTH BLOCK
        0x2581 => self.draw_block(canvas, Alignment.lower, 1, one_eighth),
        // '▂' LOWER ONE QUARTER BLOCK
        0x2582 => self.draw_block(canvas, Alignment.lower, 1, one_quarter),
        // '▃' LOWER THREE EIGHTHS BLOCK
        0x2583 => self.draw_block(canvas, Alignment.lower, 1, three_eighths),
        // '▄' LOWER HALF BLOCK
        0x2584 => self.draw_block(canvas, Alignment.lower, 1, half),
        // '▅' LOWER FIVE EIGHTHS BLOCK
        0x2585 => self.draw_block(canvas, Alignment.lower, 1, five_eighths),
        // '▆' LOWER THREE QUARTERS BLOCK
        0x2586 => self.draw_block(canvas, Alignment.lower, 1, three_quarters),
        // '▇' LOWER SEVEN EIGHTHS BLOCK
        0x2587 => self.draw_block(canvas, Alignment.lower, 1, seven_eighths),
        // '█' FULL BLOCK
        0x2588 => self.draw_full_block(canvas),
        // '▉' LEFT SEVEN EIGHTHS BLOCK
        0x2589 => self.draw_block(canvas, Alignment.left, seven_eighths, 1),
        // '▊' LEFT THREE QUARTERS BLOCK
        0x258a => self.draw_block(canvas, Alignment.left, three_quarters, 1),
        // '▋' LEFT FIVE EIGHTHS BLOCK
        0x258b => self.draw_block(canvas, Alignment.left, five_eighths, 1),
        // '▌' LEFT HALF BLOCK
        0x258c => self.draw_block(canvas, Alignment.left, half, 1),
        // '▍' LEFT THREE EIGHTHS BLOCK
        0x258d => self.draw_block(canvas, Alignment.left, three_eighths, 1),
        // '▎' LEFT ONE QUARTER BLOCK
        0x258e => self.draw_block(canvas, Alignment.left, one_quarter, 1),
        // '▏' LEFT ONE EIGHTH BLOCK
        0x258f => self.draw_block(canvas, Alignment.left, one_eighth, 1),

        // '▐' RIGHT HALF BLOCK
        0x2590 => self.draw_block(canvas, Alignment.right, half, 1),
        // '░'
        0x2591 => self.draw_light_shade(canvas),
        // '▒'
        0x2592 => self.draw_medium_shade(canvas),
        // '▓'
        0x2593 => self.draw_dark_shade(canvas),
        // '▔' UPPER ONE EIGHTH BLOCK
        0x2594 => self.draw_block(canvas, Alignment.upper, 1, one_eighth),
        // '▕' RIGHT ONE EIGHTH BLOCK
        0x2595 => self.draw_block(canvas, Alignment.right, one_eighth, 1),
        // '▖'
        0x2596 => self.draw_quadrant(canvas, .{ .bl = true }),
        // '▗'
        0x2597 => self.draw_quadrant(canvas, .{ .br = true }),
        // '▘'
        0x2598 => self.draw_quadrant(canvas, .{ .tl = true }),
        // '▙'
        0x2599 => self.draw_quadrant(canvas, .{ .tl = true, .bl = true, .br = true }),
        // '▚'
        0x259a => self.draw_quadrant(canvas, .{ .tl = true, .br = true }),
        // '▛'
        0x259b => self.draw_quadrant(canvas, .{ .tl = true, .tr = true, .bl = true }),
        // '▜'
        0x259c => self.draw_quadrant(canvas, .{ .tl = true, .tr = true, .br = true }),
        // '▝'
        0x259d => self.draw_quadrant(canvas, .{ .tr = true }),
        // '▞'
        0x259e => self.draw_quadrant(canvas, .{ .tr = true, .bl = true }),
        // '▟'
        0x259f => self.draw_quadrant(canvas, .{ .tr = true, .bl = true, .br = true }),

        0x2800...0x28ff => self.draw_braille(canvas, cp),

        0x1fb00...0x1fb3b => self.draw_sextant(canvas, cp),

        0x1fb3c...0x1fb40,
        0x1fb47...0x1fb4b,
        0x1fb57...0x1fb5b,
        0x1fb62...0x1fb66,
        0x1fb6c...0x1fb6f,
        => try self.draw_wedge_triangle(canvas, cp),

        0x1fb41...0x1fb45,
        0x1fb4c...0x1fb50,
        0x1fb52...0x1fb56,
        0x1fb5d...0x1fb61,
        0x1fb68...0x1fb6b,
        => try self.draw_wedge_triangle_inverted(alloc, canvas, cp),

        // '🭆'
        0x1fb46,
        // '🭑'
        0x1fb51,
        // '🭜'
        0x1fb5c,
        // '🭧'
        0x1fb67,
        => try self.draw_wedge_triangle_and_box(canvas, cp),

        // '🮚'
        0x1fb9a => {
            try self.draw_wedge_triangle(canvas, 0x1fb6d);
            try self.draw_wedge_triangle(canvas, 0x1fb6f);
        },

        // '🮛'
        0x1fb9b => {
            try self.draw_wedge_triangle(canvas, 0x1fb6c);
            try self.draw_wedge_triangle(canvas, 0x1fb6e);
        },

        // '🭰'
        0x1fb70 => self.draw_vertical_one_eighth_block_n(canvas, 1),
        // '🭱'
        0x1fb71 => self.draw_vertical_one_eighth_block_n(canvas, 2),
        // '🭲'
        0x1fb72 => self.draw_vertical_one_eighth_block_n(canvas, 3),
        // '🭳'
        0x1fb73 => self.draw_vertical_one_eighth_block_n(canvas, 4),
        // '🭴'
        0x1fb74 => self.draw_vertical_one_eighth_block_n(canvas, 5),
        // '🭵'
        0x1fb75 => self.draw_vertical_one_eighth_block_n(canvas, 6),

        // '🭶'
        0x1fb76 => self.draw_horizontal_one_eighth_block_n(canvas, 1),
        // '🭷'
        0x1fb77 => self.draw_horizontal_one_eighth_block_n(canvas, 2),
        // '🭸'
        0x1fb78 => self.draw_horizontal_one_eighth_block_n(canvas, 3),
        // '🭹'
        0x1fb79 => self.draw_horizontal_one_eighth_block_n(canvas, 4),
        // '🭺'
        0x1fb7a => self.draw_horizontal_one_eighth_block_n(canvas, 5),
        // '🭻'
        0x1fb7b => self.draw_horizontal_one_eighth_block_n(canvas, 6),

        // '🮂' UPPER ONE QUARTER BLOCK
        0x1fb82 => self.draw_block(canvas, Alignment.upper, 1, one_quarter),
        // '🮃' UPPER THREE EIGHTHS BLOCK
        0x1fb83 => self.draw_block(canvas, Alignment.upper, 1, three_eighths),
        // '🮄' UPPER FIVE EIGHTHS BLOCK
        0x1fb84 => self.draw_block(canvas, Alignment.upper, 1, five_eighths),
        // '🮅' UPPER THREE QUARTERS BLOCK
        0x1fb85 => self.draw_block(canvas, Alignment.upper, 1, three_quarters),
        // '🮆' UPPER SEVEN EIGHTHS BLOCK
        0x1fb86 => self.draw_block(canvas, Alignment.upper, 1, seven_eighths),

        // '🭼' LEFT AND LOWER ONE EIGHTH BLOCK
        0x1fb7c => {
            self.draw_block(canvas, Alignment.left, one_eighth, 1);
            self.draw_block(canvas, Alignment.lower, 1, one_eighth);
        },
        // '🭽' LEFT AND UPPER ONE EIGHTH BLOCK
        0x1fb7d => {
            self.draw_block(canvas, Alignment.left, one_eighth, 1);
            self.draw_block(canvas, Alignment.upper, 1, one_eighth);
        },
        // '🭾' RIGHT AND UPPER ONE EIGHTH BLOCK
        0x1fb7e => {
            self.draw_block(canvas, Alignment.right, one_eighth, 1);
            self.draw_block(canvas, Alignment.upper, 1, one_eighth);
        },
        // '🭿' RIGHT AND LOWER ONE EIGHTH BLOCK
        0x1fb7f => {
            self.draw_block(canvas, Alignment.right, one_eighth, 1);
            self.draw_block(canvas, Alignment.lower, 1, one_eighth);
        },
        // '🮀' UPPER AND LOWER ONE EIGHTH BLOCK
        0x1fb80 => {
            self.draw_block(canvas, Alignment.upper, 1, one_eighth);
            self.draw_block(canvas, Alignment.lower, 1, one_eighth);
        },
        // '🮁'
        0x1fb81 => self.draw_horizontal_one_eighth_1358_block(canvas),

        // '🮇' RIGHT ONE QUARTER BLOCK
        0x1fb87 => self.draw_block(canvas, Alignment.right, one_quarter, 1),
        // '🮈' RIGHT THREE EIGHTHS BLOCK
        0x1fb88 => self.draw_block(canvas, Alignment.right, three_eighths, 1),
        // '🮉' RIGHT FIVE EIGHTHS BLOCK
        0x1fb89 => self.draw_block(canvas, Alignment.right, five_eighths, 1),
        // '🮊' RIGHT THREE QUARTERS BLOCK
        0x1fb8a => self.draw_block(canvas, Alignment.right, three_quarters, 1),
        // '🮋' RIGHT SEVEN EIGHTHS BLOCK
        0x1fb8b => self.draw_block(canvas, Alignment.right, seven_eighths, 1),

        // Not official box characters but special characters we hide
        // in the high bits of a unicode codepoint.
        @intFromEnum(Sprite.cursor_rect) => self.draw_cursor_rect(canvas),
        @intFromEnum(Sprite.cursor_hollow_rect) => self.draw_cursor_hollow_rect(canvas),
        @intFromEnum(Sprite.cursor_bar) => self.draw_cursor_bar(canvas),

        else => return error.InvalidCodepoint,
    }
}

fn draw_lines(self: Box, canvas: *font.sprite.Canvas, comptime lines: Lines) void {
    const light_px = Thickness.light.height(self.thickness);
    const heavy_px = Thickness.heavy.height(self.thickness);

    // Top of light horizontal strokes
    const h_light_top = (self.height -| light_px) / 2;
    // Bottom of light horizontal strokes
    const h_light_bottom = h_light_top +| light_px;

    // Top of heavy horizontal strokes
    const h_heavy_top = (self.height -| heavy_px) / 2;
    // Bottom of heavy horizontal strokes
    const h_heavy_bottom = h_heavy_top +| heavy_px;

    // Top of the top doubled horizontal stroke (bottom is `h_light_top`)
    const h_double_top = h_light_top -| light_px;
    // Bottom of the bottom doubled horizontal stroke (top is `h_light_bottom`)
    const h_double_bottom = h_light_bottom +| light_px;

    // Left of light vertical strokes
    const v_light_left = (self.width -| light_px) / 2;
    // Right of light vertical strokes
    const v_light_right = v_light_left +| light_px;

    // Left of heavy vertical strokes
    const v_heavy_left = (self.width -| heavy_px) / 2;
    // Right of heavy vertical strokes
    const v_heavy_right = v_heavy_left +| heavy_px;

    // Left of the left doubled vertical stroke (right is `v_light_left`)
    const v_double_left = v_light_left -| light_px;
    // Right of the right doubled vertical stroke (left is `v_light_right`)
    const v_double_right = v_light_right +| light_px;

    // The bottom of the up line
    const up_bottom = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy_bottom
    else if (lines.left != lines.right or lines.down == lines.up)
        if (lines.left == .double or lines.right == .double)
            h_double_bottom
        else
            h_light_bottom
    else if (lines.left == .none and lines.right == .none)
        h_light_bottom
    else
        h_light_top;

    // The top of the down line
    const down_top = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy_top
    else if (lines.left != lines.right or lines.up == lines.down)
        if (lines.left == .double or lines.right == .double)
            h_double_top
        else
            h_light_top
    else if (lines.left == .none and lines.right == .none)
        h_light_top
    else
        h_light_bottom;

    // The right of the left line
    const left_right = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy_right
    else if (lines.up != lines.down or lines.left == lines.right)
        if (lines.up == .double or lines.down == .double)
            v_double_right
        else
            v_light_right
    else if (lines.up == .none and lines.down == .none)
        v_light_right
    else
        v_light_left;

    // The left of the right line
    const right_left = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy_left
    else if (lines.up != lines.down or lines.right == lines.left)
        if (lines.up == .double or lines.down == .double)
            v_double_left
        else
            v_light_left
    else if (lines.up == .none and lines.down == .none)
        v_light_left
    else
        v_light_right;

    switch (lines.up) {
        .none => {},
        .light => self.rect(canvas, v_light_left, 0, v_light_right, up_bottom),
        .heavy => self.rect(canvas, v_heavy_left, 0, v_heavy_right, up_bottom),
        .double => {
            const left_bottom = if (lines.left == .double) h_light_top else up_bottom;
            const right_bottom = if (lines.right == .double) h_light_top else up_bottom;

            self.rect(canvas, v_double_left, 0, v_light_left, left_bottom);
            self.rect(canvas, v_light_right, 0, v_double_right, right_bottom);
        },
    }

    switch (lines.right) {
        .none => {},
        .light => self.rect(canvas, right_left, h_light_top, self.width, h_light_bottom),
        .heavy => self.rect(canvas, right_left, h_heavy_top, self.width, h_heavy_bottom),
        .double => {
            const top_left = if (lines.up == .double) v_light_right else right_left;
            const bottom_left = if (lines.down == .double) v_light_right else right_left;

            self.rect(canvas, top_left, h_double_top, self.width, h_light_top);
            self.rect(canvas, bottom_left, h_light_bottom, self.width, h_double_bottom);
        },
    }

    switch (lines.down) {
        .none => {},
        .light => self.rect(canvas, v_light_left, down_top, v_light_right, self.height),
        .heavy => self.rect(canvas, v_heavy_left, down_top, v_heavy_right, self.height),
        .double => {
            const left_top = if (lines.left == .double) h_light_bottom else down_top;
            const right_top = if (lines.right == .double) h_light_bottom else down_top;

            self.rect(canvas, v_double_left, left_top, v_light_left, self.height);
            self.rect(canvas, v_light_right, right_top, v_double_right, self.height);
        },
    }

    switch (lines.left) {
        .none => {},
        .light => self.rect(canvas, 0, h_light_top, left_right, h_light_bottom),
        .heavy => self.rect(canvas, 0, h_heavy_top, left_right, h_heavy_bottom),
        .double => {
            const top_right = if (lines.up == .double) v_light_left else left_right;
            const bottom_right = if (lines.down == .double) v_light_left else left_right;

            self.rect(canvas, 0, h_double_top, top_right, h_light_top);
            self.rect(canvas, 0, h_light_bottom, bottom_right, h_double_bottom);
        },
    }
}

fn draw_light_triple_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        3,
        Thickness.light.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_heavy_triple_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        3,
        Thickness.heavy.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_light_triple_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        3,
        Thickness.light.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_heavy_triple_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        3,
        Thickness.heavy.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_light_quadruple_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        4,
        Thickness.light.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_heavy_quadruple_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        4,
        Thickness.heavy.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_light_quadruple_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        4,
        Thickness.light.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_heavy_quadruple_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        4,
        Thickness.heavy.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_light_double_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        2,
        Thickness.light.height(self.thickness),
        Thickness.light.height(self.thickness),
    );
}

fn draw_heavy_double_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        2,
        Thickness.heavy.height(self.thickness),
        Thickness.heavy.height(self.thickness),
    );
}

fn draw_light_double_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        2,
        Thickness.light.height(self.thickness),
        Thickness.heavy.height(self.thickness),
    );
}

fn draw_heavy_double_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        2,
        Thickness.heavy.height(self.thickness),
        Thickness.heavy.height(self.thickness),
    );
}

fn draw_light_diagonal_upper_right_to_lower_left(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    canvas.trapezoid(.{
        .top = 0,
        .bottom = @as(i32, @intCast(self.height)),
        .left = .{
            .p1 = .{
                .x = @as(i32, @intFromFloat(@as(f64, @floatFromInt(self.width)) - @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = 0,
            },

            .p2 = .{
                .x = @as(i32, @intFromFloat(0 - @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = @as(i32, @intCast(self.height)),
            },
        },
        .right = .{
            .p1 = .{
                .x = @as(i32, @intFromFloat(@as(f64, @floatFromInt(self.width)) + @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = 0,
            },

            .p2 = .{
                .x = @as(i32, @intFromFloat(0 + @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = @as(i32, @intCast(self.height)),
            },
        },
    });
}

fn draw_light_diagonal_upper_left_to_lower_right(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    canvas.trapezoid(.{
        .top = 0,
        .bottom = @as(i32, @intCast(self.height)),
        .left = .{
            .p1 = .{
                .x = @as(i32, @intFromFloat(0 - @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = 0,
            },

            .p2 = .{
                .x = @as(i32, @intFromFloat(@as(f64, @floatFromInt(self.width)) - @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = @as(i32, @intCast(self.height)),
            },
        },
        .right = .{
            .p1 = .{
                .x = @as(i32, @intFromFloat(0 + @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = 0,
            },

            .p2 = .{
                .x = @as(i32, @intFromFloat(@as(f64, @floatFromInt(self.width)) + @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = @as(i32, @intCast(self.height)),
            },
        },
    });
}

fn draw_light_diagonal_cross(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_light_diagonal_upper_right_to_lower_left(canvas);
    self.draw_light_diagonal_upper_left_to_lower_right(canvas);
}

fn draw_block(
    self: Box,
    canvas: *font.sprite.Canvas,
    alignment: Alignment,
    width: f64,
    height: f64,
) void {
    const float_width: f64 = @floatFromInt(self.width);
    const float_height: f64 = @floatFromInt(self.height);

    const w: u32 = @intFromFloat(@round(float_width * width));
    const h: u32 = @intFromFloat(@round(float_height * height));

    const x = switch (alignment.horizontal) {
        .left => 0,
        .right => self.width - w,
        .center => (self.width - w) / 2,
    };
    const y = switch (alignment.vertical) {
        .top => 0,
        .bottom => self.height - h,
        .middle => (self.height - h) / 2,
    };

    canvas.rect(.{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = w,
        .height = h,
    }, .on);
}

fn draw_full_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(canvas, 0, 0, self.width, self.height);
}

fn draw_vertical_one_eighth_block_n(self: Box, canvas: *font.sprite.Canvas, n: u32) void {
    const x = @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(n)) * @as(f64, @floatFromInt(self.width)) / 8)));
    const w = @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.width)) / 8)));
    self.rect(canvas, x, 0, x + w, self.height);
}

fn draw_pixman_shade(self: Box, canvas: *font.sprite.Canvas, v: u16) void {
    canvas.rect((font.sprite.Box{
        .x1 = 0,
        .y1 = 0,
        .x2 = @as(i32, @intCast(self.width)),
        .y2 = @as(i32, @intCast(self.height)),
    }).rect(), @as(font.sprite.Color, @enumFromInt(v)));
}

fn draw_light_shade(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_pixman_shade(canvas, 0x40);
}

fn draw_medium_shade(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_pixman_shade(canvas, 0x80);
}

fn draw_dark_shade(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_pixman_shade(canvas, 0xc0);
}

fn draw_horizontal_one_eighth_block_n(self: Box, canvas: *font.sprite.Canvas, n: u32) void {
    const h = @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.height)) / 8)));
    const y = @min(
        self.height -| h,
        @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(n)) * @as(f64, @floatFromInt(self.height)) / 8))),
    );
    self.rect(canvas, 0, y, self.width, y + h);
}

fn draw_horizontal_one_eighth_1358_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_horizontal_one_eighth_block_n(canvas, 0);
    self.draw_horizontal_one_eighth_block_n(canvas, 2);
    self.draw_horizontal_one_eighth_block_n(canvas, 4);
    self.draw_horizontal_one_eighth_block_n(canvas, 7);
}

fn draw_quadrant(self: Box, canvas: *font.sprite.Canvas, comptime quads: Quads) void {
    const center_x = self.width / 2 + self.width % 2;
    const center_y = self.height / 2 + self.height % 2;

    if (quads.tl) self.rect(canvas, 0, 0, center_x, center_y);
    if (quads.tr) self.rect(canvas, center_x, 0, self.width, center_y);
    if (quads.bl) self.rect(canvas, 0, center_y, center_x, self.height);
    if (quads.br) self.rect(canvas, center_x, center_y, self.width, self.height);
}

fn draw_braille(self: Box, canvas: *font.sprite.Canvas, cp: u32) void {
    var w: u32 = @min(self.width / 4, self.height / 8);
    var x_spacing: u32 = self.width / 4;
    var y_spacing: u32 = self.height / 8;
    var x_margin: u32 = x_spacing / 2;
    var y_margin: u32 = y_spacing / 2;

    var x_px_left: u32 = self.width - 2 * x_margin - x_spacing - 2 * w;
    var y_px_left: u32 = self.height - 2 * y_margin - 3 * y_spacing - 4 * w;

    // First, try hard to ensure the DOT width is non-zero
    if (x_px_left >= 2 and y_px_left >= 4 and w == 0) {
        w += 1;
        x_px_left -= 2;
        y_px_left -= 4;
    }

    // Second, prefer a non-zero margin
    if (x_px_left >= 2 and x_margin == 0) {
        x_margin = 1;
        x_px_left -= 2;
    }
    if (y_px_left >= 2 and y_margin == 0) {
        y_margin = 1;
        y_px_left -= 2;
    }

    // Third, increase spacing
    if (x_px_left >= 1) {
        x_spacing += 1;
        x_px_left -= 1;
    }
    if (y_px_left >= 3) {
        y_spacing += 1;
        y_px_left -= 3;
    }

    // Fourth, margins (“spacing”, but on the sides)
    if (x_px_left >= 2) {
        x_margin += 1;
        x_px_left -= 2;
    }
    if (y_px_left >= 2) {
        y_margin += 1;
        y_px_left -= 2;
    }

    // Last - increase dot width
    if (x_px_left >= 2 and y_px_left >= 4) {
        w += 1;
        x_px_left -= 2;
        y_px_left -= 4;
    }

    assert(x_px_left <= 1 or y_px_left <= 1);
    assert(2 * x_margin + 2 * w + x_spacing <= self.width);
    assert(2 * y_margin + 4 * w + 3 * y_spacing <= self.height);

    const x = [2]u32{ x_margin, x_margin + w + x_spacing };
    const y = y: {
        var y: [4]u32 = undefined;
        y[0] = y_margin;
        y[1] = y[0] + w + y_spacing;
        y[2] = y[1] + w + y_spacing;
        y[3] = y[2] + w + y_spacing;
        break :y y;
    };

    assert(cp >= 0x2800);
    assert(cp <= 0x28ff);
    const sym = cp - 0x2800;

    // Left side
    if (sym & 1 > 0)
        self.rect(canvas, x[0], y[0], x[0] + w, y[0] + w);
    if (sym & 2 > 0)
        self.rect(canvas, x[0], y[1], x[0] + w, y[1] + w);
    if (sym & 4 > 0)
        self.rect(canvas, x[0], y[2], x[0] + w, y[2] + w);

    // Right side
    if (sym & 8 > 0)
        self.rect(canvas, x[1], y[0], x[1] + w, y[0] + w);
    if (sym & 16 > 0)
        self.rect(canvas, x[1], y[1], x[1] + w, y[1] + w);
    if (sym & 32 > 0)
        self.rect(canvas, x[1], y[2], x[1] + w, y[2] + w);

    // 8-dot patterns
    if (sym & 64 > 0)
        self.rect(canvas, x[0], y[3], x[0] + w, y[3] + w);
    if (sym & 128 > 0)
        self.rect(canvas, x[1], y[3], x[1] + w, y[3] + w);
}

fn draw_sextant(self: Box, canvas: *font.sprite.Canvas, cp: u32) void {
    const Sextants = packed struct(u6) {
        tl: bool,
        tr: bool,
        ml: bool,
        mr: bool,
        bl: bool,
        br: bool,
    };

    assert(cp >= 0x1fb00 and cp <= 0x1fb3b);
    const idx = cp - 0x1fb00;
    const sex: Sextants = @bitCast(@as(u6, @intCast(
        idx + (idx / 0x14) + 1,
    )));

    const x_halfs = self.xHalfs();
    const y_thirds = self.yThirds();

    if (sex.tl) self.rect(canvas, 0, 0, x_halfs[0], y_thirds[0]);
    if (sex.tr) self.rect(canvas, x_halfs[1], 0, self.width, y_thirds[0]);
    if (sex.ml) self.rect(canvas, 0, y_thirds[0], x_halfs[0], y_thirds[1]);
    if (sex.mr) self.rect(canvas, x_halfs[1], y_thirds[0], self.width, y_thirds[1]);
    if (sex.bl) self.rect(canvas, 0, y_thirds[1], x_halfs[0], self.height);
    if (sex.br) self.rect(canvas, x_halfs[1], y_thirds[1], self.width, self.height);
}

fn xHalfs(self: Box) [2]u32 {
    return .{
        @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.width)) / 2))),
        @as(u32, @intFromFloat(@as(f64, @floatFromInt(self.width)) / 2)),
    };
}

fn yThirds(self: Box) [2]u32 {
    return switch (@mod(self.height, 3)) {
        0 => .{ self.height / 3, 2 * self.height / 3 },
        1 => .{ self.height / 3, 2 * self.height / 3 + 1 },
        2 => .{ self.height / 3 + 1, 2 * self.height / 3 },
        else => unreachable,
    };
}

fn draw_wedge_triangle(self: Box, canvas: *font.sprite.Canvas, cp: u32) !void {
    const width = self.width;
    const height = self.height;

    const x_halfs = self.xHalfs();
    const y_thirds = self.yThirds();
    const halfs0 = x_halfs[0];
    const halfs1 = x_halfs[1];
    const thirds0 = y_thirds[0];
    const thirds1 = y_thirds[1];

    var p1_x: u32 = 0;
    var p2_x: u32 = 0;
    var p3_x: u32 = 0;
    var p1_y: u32 = 0;
    var p2_y: u32 = 0;
    var p3_y: u32 = 0;

    switch (cp) {
        0x1fb3c => {
            p3_x = halfs0;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb52 => {
            p3_x = halfs0;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb3d => {
            p3_x = width;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb53 => {
            p3_x = width;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb3e => {
            p3_x = halfs0;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb54 => {
            p3_x = halfs0;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb3f => {
            p3_x = width;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb55 => {
            p3_x = width;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb40, 0x1fb56 => {
            p3_x = halfs0;
            p1_y = 0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb47 => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb5d => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb48 => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb5e => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb49 => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb5f => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb4a => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb60 => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb4b, 0x1fb61 => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = 0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb57 => {
            p3_x = halfs0;
            p2_y = thirds0;
        },

        0x1fb41 => {
            p3_x = halfs0;
            p2_y = thirds0;
        },

        0x1fb58 => {
            p3_x = width;
            p2_y = thirds0;
        },

        0x1fb42 => {
            p3_x = width;
            p2_y = thirds0;
        },

        0x1fb59 => {
            p3_x = halfs0;
            p2_y = thirds1;
        },

        0x1fb43 => {
            p3_x = halfs0;
            p2_y = thirds1;
        },

        0x1fb5a => {
            p3_x = width;
            p2_y = thirds1;
        },

        0x1fb44 => {
            p3_x = width;
            p2_y = thirds1;
        },

        0x1fb5b, 0x1fb45 => {
            p3_x = halfs0;
            p2_y = height;
        },

        0x1fb62 => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p2_y = thirds0;
        },

        0x1fb4c => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p2_y = thirds0;
        },

        0x1fb63 => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p2_y = thirds0;
        },

        0x1fb4d => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p2_y = thirds0;
        },

        0x1fb64 => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p2_y = thirds1;
        },

        0x1fb4e => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p2_y = thirds1;
        },

        0x1fb65 => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p2_y = thirds1;
        },

        0x1fb4f => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p2_y = thirds1;
        },

        0x1fb66, 0x1fb50 => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p2_y = height;
        },

        0x1fb46 => {
            p1_x = 0;
            p1_y = thirds1;
            p2_x = width;
            p2_y = thirds0;
            p3_x = width;
            p3_y = p1_y;
        },

        0x1fb51 => {
            p1_x = 0;
            p1_y = thirds0;
            p2_x = 0;
            p2_y = thirds1;
            p3_x = width;
            p3_y = p2_y;
        },

        0x1fb5c => {
            p1_x = 0;
            p1_y = thirds0;
            p2_x = 0;
            p2_y = thirds1;
            p3_x = width;
            p3_y = p1_y;
        },

        0x1fb67 => {
            p1_x = 0;
            p1_y = thirds0;
            p2_x = width;
            p2_y = p1_y;
            p3_x = width;
            p3_y = thirds1;
        },

        0x1fb6c, 0x1fb68 => {
            p1_x = 0;
            p1_y = 0;
            p2_x = halfs0;
            p2_y = height / 2;
            p3_x = 0;
            p3_y = height;
        },

        0x1fb6d, 0x1fb69 => {
            p1_x = 0;
            p1_y = 0;
            p2_x = halfs1;
            p2_y = height / 2;
            p3_x = width;
            p3_y = 0;
        },

        0x1fb6e, 0x1fb6a => {
            p1_x = width;
            p1_y = 0;
            p2_x = halfs1;
            p2_y = height / 2;
            p3_x = width;
            p3_y = height;
        },

        0x1fb6f, 0x1fb6b => {
            p1_x = 0;
            p1_y = height;
            p2_x = halfs1;
            p2_y = height / 2;
            p3_x = width;
            p3_y = height;
        },

        else => unreachable,
    }

    canvas.triangle(.{
        .p1 = .{ .x = @as(i32, @intCast(p1_x)), .y = @as(i32, @intCast(p1_y)) },
        .p2 = .{ .x = @as(i32, @intCast(p2_x)), .y = @as(i32, @intCast(p2_y)) },
        .p3 = .{ .x = @as(i32, @intCast(p3_x)), .y = @as(i32, @intCast(p3_y)) },
    }, .on);
}

fn draw_wedge_triangle_inverted(
    self: Box,
    alloc: Allocator,
    canvas: *font.sprite.Canvas,
    cp: u32,
) !void {
    try self.draw_wedge_triangle(canvas, cp);

    var src = try font.sprite.Canvas.init(alloc, self.width, self.height);
    src.rect(.{ .x = 0, .y = 0, .width = self.width, .height = self.height }, .on);
    defer src.deinit(alloc);
    canvas.composite(
        .source_out,
        &src,
        .{ .x = 0, .y = 0, .width = self.width, .height = self.height },
    );
}

fn draw_wedge_triangle_and_box(self: Box, canvas: *font.sprite.Canvas, cp: u32) !void {
    try self.draw_wedge_triangle(canvas, cp);

    const y_thirds = self.yThirds();
    const box: font.sprite.Box = switch (cp) {
        0x1fb46, 0x1fb51 => .{
            .x1 = 0,
            .y1 = @as(i32, @intCast(y_thirds[1])),
            .x2 = @as(i32, @intCast(self.width)),
            .y2 = @as(i32, @intCast(self.height)),
        },

        0x1fb5c, 0x1fb67 => .{
            .x1 = 0,
            .y1 = 0,
            .x2 = @as(i32, @intCast(self.width)),
            .y2 = @as(i32, @intCast(y_thirds[0])),
        },

        else => unreachable,
    };

    canvas.rect(box.rect(), .on);
}

fn draw_light_arc(
    self: Box,
    alloc: Allocator,
    canvas: *font.sprite.Canvas,
    cp: u32,
) !void {
    const supersample = 4;
    const height = self.height * supersample;
    const width = self.width * supersample;

    // Allocate our supersample sized canvas
    var ss_data = try alloc.alloc(u8, height * width);
    defer alloc.free(ss_data);
    @memset(ss_data, 0);

    const height_pixels = self.height;
    const width_pixels = self.width;
    const thick_pixels = Thickness.light.height(self.thickness);
    const thick = thick_pixels * supersample;

    const circle_inner_edge = (@min(width_pixels, height_pixels) -| thick_pixels) / 2;

    // We want to draw the quartercircle by filling small circles (with r =
    // thickness/2.) whose centers are on its edge. This means to get the
    // radius of the quartercircle, we add the exact half thickness to the
    // radius of the inner circle.
    var c_r: f64 = @as(f64, @floatFromInt(circle_inner_edge)) + @as(f64, @floatFromInt(thick_pixels)) / 2;

    // We need to draw short lines from the end of the quartercircle to the
    // box-edges, store one endpoint (the other is the edge of the
    // quartercircle) in these vars.
    var vert_to: u32 = 0;
    var hor_to: u32 = 0;

    // Coordinates of the circle-center.
    var c_x: u32 = 0;
    var c_y: u32 = 0;

    // For a given y there are up to two solutions for the circle-equation.
    // Set to -1 for the left, and 1 for the right hemisphere.
    var circle_hemisphere: i32 = 0;

    // The quarter circle only has to be evaluated for a small range of
    // y-values.
    var y_min: u32 = 0;
    var y_max: u32 = 0;

    switch (cp) {
        '╭' => {
            // Don't use supersampled coordinates yet, we want to align actual
            // pixels.
            //
            // pixel-coordinates of the lower edge of the right line and the
            // right edge of the bottom line.
            const right_bottom_edge = (height_pixels + thick_pixels) / 2;
            const bottom_right_edge = (width_pixels + thick_pixels) / 2;

            // find coordinates of circle-center.
            c_y = right_bottom_edge + circle_inner_edge;
            c_x = bottom_right_edge + circle_inner_edge;

            // we want to render the left, not the right hemisphere of the circle.
            circle_hemisphere = -1;

            // don't evaluate beyond c_y, the vertical line is drawn there.
            y_min = 0;
            y_max = c_y;

            // the vertical line should extend to the bottom of the box, the
            // horizontal to the right.
            vert_to = height_pixels;
            hor_to = width_pixels;
        },
        '╮' => {
            const left_bottom_edge = (height_pixels + thick_pixels) / 2;
            const bottom_left_edge = (width_pixels -| thick_pixels) / 2;

            c_y = left_bottom_edge + circle_inner_edge;
            c_x = bottom_left_edge -| circle_inner_edge;

            circle_hemisphere = 1;

            y_min = 0;
            y_max = c_y;

            vert_to = height_pixels;
            hor_to = 0;
        },
        '╰' => {
            const right_top_edge = (height_pixels -| thick_pixels) / 2;
            const top_right_edge = (width_pixels + thick_pixels) / 2;

            c_y = right_top_edge -| circle_inner_edge;
            c_x = top_right_edge + circle_inner_edge;

            circle_hemisphere = -1;

            y_min = c_y;
            y_max = height_pixels;

            vert_to = 0;
            hor_to = width_pixels;
        },
        '╯' => {
            const left_top_edge = (height_pixels -| thick_pixels) / 2;
            const top_left_edge = (width_pixels -| thick_pixels) / 2;

            c_y = left_top_edge -| circle_inner_edge;
            c_x = top_left_edge -| circle_inner_edge;

            circle_hemisphere = 1;

            y_min = c_y;
            y_max = height_pixels;

            vert_to = 0;
            hor_to = 0;
        },

        else => {},
    }

    // store for horizontal+vertical line.
    const c_x_pixels = c_x;
    const c_y_pixels = c_y;

    // Bring coordinates from pixel-grid to supersampled grid.
    c_r *= supersample;
    c_x *= supersample;
    c_y *= supersample;

    y_min *= supersample;
    y_max *= supersample;

    const c_r2 = c_r * c_r;

    // To prevent gaps in the circle, each pixel is sampled multiple times.
    // As the quartercircle ends (vertically) in the middle of a pixel, an
    // uneven number helps hit that exactly.
    {
        var i: f64 = @as(f64, @floatFromInt(y_min)) * 16;
        while (i <= @as(f64, @floatFromInt(y_max)) * 16) : (i += 1) {
            const y = i / 16;
            const x = x: {
                // circle_hemisphere * sqrt(c_r2 - (y - c_y) * (y - c_y)) + c_x;
                const hemi = @as(f64, @floatFromInt(circle_hemisphere));
                const y_part = y - @as(f64, @floatFromInt(c_y));
                const y_squared = y_part * y_part;
                const sqrt = @sqrt(c_r2 - y_squared);
                const f_c_x = @as(f64, @floatFromInt(c_x));

                // We need to detect overflows and just skip this i
                const a = hemi * sqrt;
                const b = a + f_c_x;

                // If the float math didn't work, ignore.
                if (std.math.isNan(b)) continue;

                break :x b;
            };

            const row = @as(i32, @intFromFloat(@round(y)));
            const col = @as(i32, @intFromFloat(@round(x)));
            if (col < 0) continue;

            // rectangle big enough to fit entire circle with radius thick/2.
            const row1 = row - @as(i32, @intCast(thick / 2 + 1));
            const row2 = row + @as(i32, @intCast(thick / 2 + 1));
            const col1 = col - @as(i32, @intCast(thick / 2 + 1));
            const col2 = col + @as(i32, @intCast(thick / 2 + 1));

            const row_start = @min(row1, row2);
            const row_end = @max(row1, row2);
            const col_start = @min(col1, col2);
            const col_end = @max(col1, col2);

            assert(row_end > row_start);
            assert(col_end > col_start);

            // draw circle with radius thick/2 around x,y.
            // this is accomplished by rejecting pixels where the distance from
            // their center to x,y is greater than thick/2.
            var r: i32 = @max(row_start, 0);
            const r_end = @max(@min(row_end, @as(i32, @intCast(height))), 0);
            while (r < r_end) : (r += 1) {
                const r_midpoint = @as(f64, @floatFromInt(r)) + 0.5;

                var c: i32 = @max(col_start, 0);
                const c_end = @max(@min(col_end, @as(i32, @intCast(width))), 0);
                while (c < c_end) : (c += 1) {
                    const c_midpoint = @as(f64, @floatFromInt(c)) + 0.5;

                    // vector from point on quartercircle to midpoint of the current pixel.
                    const center_midpoint_x = c_midpoint - x;
                    const center_midpoint_y = r_midpoint - y;

                    // distance from current point to circle-center.
                    const dist = @sqrt(center_midpoint_x * center_midpoint_x + center_midpoint_y * center_midpoint_y);
                    // skip if midpoint of pixel is outside the circle.
                    if (dist > @as(f64, @floatFromInt(thick)) / 2) continue;

                    // Set our pixel
                    const idx = @as(usize, @intCast(r * @as(i32, @intCast(width)) + c));
                    ss_data[idx] = 0xFF;
                }
            }
        }
    }

    // Downsample
    {
        var r: u32 = 0;
        while (r < self.height) : (r += 1) {
            var c: u32 = 0;
            while (c < self.width) : (c += 1) {
                var total: u32 = 0;
                var i: usize = 0;
                while (i < supersample) : (i += 1) {
                    var j: usize = 0;
                    while (j < supersample) : (j += 1) {
                        const idx = (r * supersample + i) * width + (c * supersample + j);
                        total += ss_data[idx];
                    }
                }

                const average = @as(u8, @intCast(@min(total / (supersample * supersample), 0xff)));
                canvas.rect(
                    .{
                        .x = @as(i32, @intCast(c)),
                        .y = @as(i32, @intCast(r)),
                        .width = 1,
                        .height = 1,
                    },
                    @as(font.sprite.Color, @enumFromInt(average)),
                );
            }
        }
    }

    // draw vertical/horizontal lines from quartercircle-edge to box-edge.
    self.vline(canvas, @min(c_y_pixels, vert_to), @max(c_y_pixels, vert_to), (width_pixels - thick_pixels) / 2, thick_pixels);
    self.hline(canvas, @min(c_x_pixels, hor_to), @max(c_x_pixels, hor_to), (height_pixels - thick_pixels) / 2, thick_pixels);
}

fn draw_dash_horizontal(
    self: Box,
    canvas: *font.sprite.Canvas,
    count: u8,
    thick_px: u32,
    desired_gap: u32,
) void {
    assert(count >= 2 and count <= 4);

    // +------------+
    // |            |
    // |            |
    // |            |
    // |            |
    // | --  --  -- |
    // |            |
    // |            |
    // |            |
    // |            |
    // +------------+
    // Our dashed line should be made such that when tiled horizontally
    // it creates one consistent line with no uneven gap or segment sizes.
    // In order to make sure this is the case, we should have half-sized
    // gaps on the left and right so that it is centered properly.

    // For N dashes, there are N - 1 gaps between them, but we also have
    // half-sized gaps on either side, adding up to N total gaps.
    const gap_count = count;

    // We need at least 1 pixel for each gap and each dash, if we don't
    // have that then we can't draw our dashed line correctly so we just
    // draw a solid line and return.
    if (self.width < count + gap_count) {
        self.hline_middle(canvas, .light);
        return;
    }

    // We never want the gaps to take up more than 50% of the space,
    // because if they do the dashes are too small and look wrong.
    const gap_width = @min(desired_gap, self.width / (2 * count));
    const total_gap_width = gap_count * gap_width;
    const total_dash_width = self.width - total_gap_width;
    const dash_width = total_dash_width / count;
    const remaining = total_dash_width % count;

    assert(dash_width * count + gap_width * gap_count + remaining == self.width);

    // Our dashes should be centered vertically.
    const y: u32 = (self.height -| thick_px) / 2;

    // We start at half a gap from the left edge, in order to center
    // our dashes properly.
    var x: u32 = gap_width / 2;

    // We'll distribute the extra space in to dash widths, 1px at a
    // time. We prefer this to making gaps larger since that is much
    // more visually obvious.
    var extra: u32 = remaining;

    for (0..count) |_| {
        var x1 = x + dash_width;
        // We distribute left-over size in to dash widths,
        // since it's less obvious there than in the gaps.
        if (extra > 0) {
            extra -= 1;
            x1 += 1;
        }
        self.hline(canvas, x, x1, y, thick_px);
        // Advance by the width of the dash we drew and the width
        // of a gap to get the the start of the next dash.
        x = x1 + gap_width;
    }
}

fn draw_dash_vertical(
    self: Box,
    canvas: *font.sprite.Canvas,
    comptime count: u8,
    thick_px: u32,
    desired_gap: u32,
) void {
    assert(count >= 2 and count <= 4);

    // +-----------+
    // |     |     |
    // |     |     |
    // |           |
    // |     |     |
    // |     |     |
    // |           |
    // |     |     |
    // |     |     |
    // |           |
    // +-----------+
    // Our dashed line should be made such that when tiled vertically it
    // it creates one consistent line with no uneven gap or segment sizes.
    // In order to make sure this is the case, we should have an extra gap
    // gap at the bottom.
    //
    // A single full-sized extra gap is preferred to two half-sized ones for
    // vertical to allow better joining to solid characters without creating
    // visible half-sized gaps. Unlike horizontal, centering is a lot less
    // important, visually.

    // Because of the extra gap at the bottom, there are as many gaps as
    // there are dashes.
    const gap_count = count;

    // We need at least 1 pixel for each gap and each dash, if we don't
    // have that then we can't draw our dashed line correctly so we just
    // draw a solid line and return.
    if (self.height < count + gap_count) {
        self.vline_middle(canvas, .light);
        return;
    }

    // We never want the gaps to take up more than 50% of the space,
    // because if they do the dashes are too small and look wrong.
    const gap_height = @min(desired_gap, self.height / (2 * count));
    const total_gap_height = gap_count * gap_height;
    const total_dash_height = self.height - total_gap_height;
    const dash_height = total_dash_height / count;
    const remaining = total_dash_height % count;

    assert(dash_height * count + gap_height * gap_count + remaining == self.height);

    // Our dashes should be centered horizontally.
    const x: u32 = (self.width -| thick_px) / 2;

    // We start at the top of the cell.
    var y: u32 = 0;

    // We'll distribute the extra space in to dash heights, 1px at a
    // time. We prefer this to making gaps larger since that is much
    // more visually obvious.
    var extra: u32 = remaining;

    inline for (0..count) |_| {
        var y1 = y + dash_height;
        // We distribute left-over size in to dash widths,
        // since it's less obvious there than in the gaps.
        if (extra > 0) {
            extra -= 1;
            y1 += 1;
        }
        self.vline(canvas, y, y1, x, thick_px);
        // Advance by the height of the dash we drew and the height
        // of a gap to get the the start of the next dash.
        y = y1 + gap_height;
    }
}

fn draw_cursor_rect(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(canvas, 0, 0, self.width, self.height);
}

fn draw_cursor_hollow_rect(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.super_light.height(self.thickness);

    self.vline(canvas, 0, self.height, 0, thick_px);
    self.vline(canvas, 0, self.height, self.width -| thick_px, thick_px);
    self.hline(canvas, 0, self.width, 0, thick_px);
    self.hline(canvas, 0, self.width, self.height -| thick_px, thick_px);
}

fn draw_cursor_bar(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);

    self.vline(canvas, 0, self.height, 0, thick_px);
}

fn vline_middle(self: Box, canvas: *font.sprite.Canvas, thickness: Thickness) void {
    const thick_px = thickness.height(self.thickness);
    self.vline(canvas, 0, self.height, (self.width -| thick_px) / 2, thick_px);
}

fn hline_middle(self: Box, canvas: *font.sprite.Canvas, thickness: Thickness) void {
    const thick_px = thickness.height(self.thickness);
    self.hline(canvas, 0, self.width, (self.height -| thick_px) / 2, thick_px);
}

fn vline(
    self: Box,
    canvas: *font.sprite.Canvas,
    y1: u32,
    y2: u32,
    x: u32,
    thickness_px: u32,
) void {
    canvas.rect((font.sprite.Box{
        .x1 = @as(i32, @intCast(@min(@max(x, 0), self.width))),
        .x2 = @as(i32, @intCast(@min(@max(x + thickness_px, 0), self.width))),
        .y1 = @as(i32, @intCast(@min(@max(y1, 0), self.height))),
        .y2 = @as(i32, @intCast(@min(@max(y2, 0), self.height))),
    }).rect(), .on);
}

fn hline(
    self: Box,
    canvas: *font.sprite.Canvas,
    x1: u32,
    x2: u32,
    y: u32,
    thickness_px: u32,
) void {
    canvas.rect((font.sprite.Box{
        .x1 = @as(i32, @intCast(@min(@max(x1, 0), self.width))),
        .x2 = @as(i32, @intCast(@min(@max(x2, 0), self.width))),
        .y1 = @as(i32, @intCast(@min(@max(y, 0), self.height))),
        .y2 = @as(i32, @intCast(@min(@max(y + thickness_px, 0), self.height))),
    }).rect(), .on);
}

fn rect(
    self: Box,
    canvas: *font.sprite.Canvas,
    x1: u32,
    y1: u32,
    x2: u32,
    y2: u32,
) void {
    canvas.rect((font.sprite.Box{
        .x1 = @as(i32, @intCast(@min(@max(x1, 0), self.width))),
        .y1 = @as(i32, @intCast(@min(@max(y1, 0), self.height))),
        .x2 = @as(i32, @intCast(@min(@max(x2, 0), self.width))),
        .y2 = @as(i32, @intCast(@min(@max(y2, 0), self.height))),
    }).rect(), .on);
}

test "all" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cp: u32 = 0x2500;
    const end = 0x259f;
    while (cp <= end) : (cp += 1) {
        var atlas_grayscale = try font.Atlas.init(alloc, 512, .grayscale);
        defer atlas_grayscale.deinit(alloc);

        const face: Box = .{ .width = 18, .height = 36, .thickness = 2 };
        const glyph = try face.renderGlyph(
            alloc,
            &atlas_grayscale,
            cp,
        );
        try testing.expectEqual(@as(u32, face.width), glyph.width);
        try testing.expectEqual(@as(u32, face.height), glyph.height);
    }
}

test "render all sprites" {
    // Renders all sprites to an atlas and compares
    // it to a ground truth for regression testing.

    const testing = std.testing;
    const alloc = testing.allocator;

    var atlas_grayscale = try font.Atlas.init(alloc, 1024, .grayscale);
    defer atlas_grayscale.deinit(alloc);

    const face: Box = .{ .width = 18, .height = 36, .thickness = 2 };

    // Box Drawing and Block Elements.
    var cp: u32 = 0x2500;
    while (cp <= 0x259f) : (cp += 1) {
        _ = try face.renderGlyph(
            alloc,
            &atlas_grayscale,
            cp,
        );
    }

    // Braille
    cp = 0x2800;
    while (cp <= 0x28ff) : (cp += 1) {
        _ = try face.renderGlyph(
            alloc,
            &atlas_grayscale,
            cp,
        );
    }

    // Symbols for Legacy Computing.
    cp = 0x1fb00;
    while (cp <= 0x1fb9b) : (cp += 1) {
        switch (cp) {
            0x1FB00...0x1FB3B,
            0x1FB3C...0x1FB40,
            0x1FB47...0x1FB4B,
            0x1FB57...0x1FB5B,
            0x1FB62...0x1FB66,
            0x1FB6C...0x1FB6F,
            0x1FB41...0x1FB45,
            0x1FB4C...0x1FB50,
            0x1FB52...0x1FB56,
            0x1FB5D...0x1FB61,
            0x1FB68...0x1FB6B,
            0x1FB70...0x1FB8B,
            0x1FB46,
            0x1FB51,
            0x1FB5C,
            0x1FB67,
            0x1FB9A,
            0x1FB9B,
            => _ = try face.renderGlyph(
                alloc,
                &atlas_grayscale,
                cp,
            ),
            else => {},
        }
    }

    const ground_truth = @embedFile("./testdata/Box.ppm");

    var stream = std.io.changeDetectionStream(ground_truth, std.io.null_writer);
    try atlas_grayscale.dump(stream.writer());

    if (stream.changeDetected()) {
        log.err(
            \\
            \\!! [Box.zig] Change detected from ground truth!
            \\!! Dumping ./Box_test.ppm and ./Box_test_diff.ppm
            \\!! Please check changes and update Box.ppm in testdata if intended.
        ,
            .{},
        );

        const ppm = try std.fs.cwd().createFile("Box_test.ppm", .{});
        defer ppm.close();
        try atlas_grayscale.dump(ppm.writer());

        const diff = try std.fs.cwd().createFile("Box_test_diff.ppm", .{});
        defer diff.close();
        var writer = diff.writer();
        try writer.print(
            \\P6
            \\{d} {d}
            \\255
            \\
        , .{ atlas_grayscale.size, atlas_grayscale.size });
        for (ground_truth[try diff.getPos()..], atlas_grayscale.data) |a, b| {
            if (a == b) {
                try writer.writeByteNTimes(a / 3, 3);
            } else {
                try writer.writeByte(a);
                try writer.writeByte(b);
                try writer.writeByte(0);
            }
        }
    }
}
