#version 330 core

// These are the possible modes that "mode" can be set to. This is
// used to multiplex multiple render modes into a single shader.
//
// NOTE: this must be kept in sync with the fragment shader
const uint MODE_BG = 1u;
const uint MODE_FG = 2u;
const uint MODE_CURSOR_RECT = 3u;
const uint MODE_CURSOR_RECT_HOLLOW = 4u;
const uint MODE_CURSOR_BAR = 5u;
const uint MODE_UNDERLINE = 6u;

// The grid coordinates (x, y) where x < columns and y < rows
layout (location = 0) in vec2 grid_coord;

// Position of the glyph in the texture.
layout (location = 1) in vec2 glyph_pos;

// Width/height of the glyph
layout (location = 2) in vec2 glyph_size;

// Offset of the top-left corner of the glyph when rendered in a rect.
layout (location = 3) in vec2 glyph_offset;

// The background color for this cell in RGBA (0 to 1.0)
layout (location = 4) in vec4 fg_color_in;

// The background color for this cell in RGBA (0 to 1.0)
layout (location = 5) in vec4 bg_color_in;

// The mode of this shader. The mode determines what fields are used,
// what the output will be, etc. This shader is capable of executing in
// multiple "modes" so that we can share some logic and so that we can draw
// the entire terminal grid in a single GPU pass.
layout (location = 6) in uint mode_in;

// The background or foreground color for the fragment, depending on
// whether this is a background or foreground pass.
flat out vec4 color;

// The x/y coordinate for the glyph representing the font.
out vec2 glyph_tex_coords;

// The position of the cell top-left corner in screen cords. z and w
// are width and height.
flat out vec2 screen_cell_pos;

// Pass the mode forward to the fragment shader.
flat out uint mode;

uniform sampler2D text;
uniform vec2 cell_size;
uniform mat4 projection;
uniform float glyph_baseline;

/********************************************************************
 * Modes
 *
 *-------------------------------------------------------------------
 * MODE_BG
 *
 * In MODE_BG, this shader renders only the background color for the
 * cell. This is a simple mode where we generate a simple rectangle
 * made up of 4 vertices and then it is filled. In this mode, the output
 * "color" is the fill color for the bg.
 *
 *-------------------------------------------------------------------
 * MODE_FG
 *
 * In MODE_FG, the shader renders the glyph onto this cell and utilizes
 * the glyph texture "text". In this mode, the output "color" is the
 * fg color to use for the glyph.
 *
 */

void main() {
    // We always forward our mode
    mode = mode_in;

    // Top-left cell coordinates converted to world space
    // Example: (1,0) with a 30 wide cell is converted to (30,0)
    vec2 cell_pos = cell_size * grid_coord;

    // Turn the cell position into a vertex point depending on the
    // gl_VertexID. Since we use instanced drawing, we have 4 vertices
    // for each corner of the cell. We can use gl_VertexID to determine
    // which one we're looking at. Using this, we can use 1 or 0 to keep
    // or discard the value for the vertex.
    //
    // 0 = top-right
    // 1 = bot-right
    // 2 = bot-left
    // 3 = top-left
    vec2 position;
    position.x = (gl_VertexID == 0 || gl_VertexID == 1) ? 1. : 0.;
    position.y = (gl_VertexID == 0 || gl_VertexID == 3) ? 0. : 1.;

    switch (mode_in) {
    case MODE_BG:
        // Calculate the final position of our cell in world space.
        // We have to add our cell size since our vertices are offset
        // one cell up and to the left. (Do the math to verify yourself)
        cell_pos = cell_pos + cell_size * position;

        gl_Position = projection * vec4(cell_pos, 0.0, 1.0);
        color = bg_color_in / 255.0;
        break;

    case MODE_FG:
        // The glyph_offset.y is the y bearing, a y value that when added
        // to the baseline is the offset (+y is up). Our grid goes down.
        // So we flip it with `cell_size.y - glyph_offset.y`. The glyph_baseline
        // uniform sets our line baseline where characters "sit".
        vec2 glyph_offset_calc = glyph_offset;
        glyph_offset_calc.y = cell_size.y - glyph_offset.y - glyph_baseline;

        // Calculate the final position of the cell.
        cell_pos = cell_pos + glyph_size * position + glyph_offset_calc;
        gl_Position = projection * vec4(cell_pos, 0.0, 1.0);

        // We need to convert our texture position and size to normalized
        // device coordinates (0 to 1.0) by dividing by the size of the texture.
        ivec2 text_size = textureSize(text, 0);
        vec2 glyph_tex_pos = glyph_pos / text_size;
        vec2 glyph_tex_size = glyph_size / text_size;
        glyph_tex_coords = glyph_tex_pos + glyph_tex_size * position;

        // Set our foreground color output
        color = fg_color_in / 255.;
        break;

    case MODE_CURSOR_RECT:
        // Same as background since we're taking up the whole cell.
        cell_pos = cell_pos + cell_size * position;

        gl_Position = projection * vec4(cell_pos, 0.0, 1.0);
        color = bg_color_in / 255.0;
        break;

    case MODE_CURSOR_RECT_HOLLOW:
        // Top-left position of this cell is needed for the hollow rect.
        screen_cell_pos = cell_pos;

        // Same as background since we're taking up the whole cell.
        cell_pos = cell_pos + cell_size * position;

        gl_Position = projection * vec4(cell_pos, 0.0, 1.0);
        color = bg_color_in / 255.0;
        break;

    case MODE_CURSOR_BAR:
        // Make the bar a smaller version of our cell
        vec2 bar_size = vec2(cell_size.x * 0.2, cell_size.y);

        // Same as background since we're taking up the whole cell.
        cell_pos = cell_pos + bar_size * position;

        gl_Position = projection * vec4(cell_pos, 0.0, 1.0);
        color = bg_color_in / 255.0;
        break;

    case MODE_UNDERLINE:
        // Make the underline a smaller version of our cell
        // TODO: use real font underline thickness
        vec2 underline_size = vec2(cell_size.x, cell_size.y*0.05);

        // Position our underline so that it is midway between the glyph
        // baseline and the bottom of the cell.
        vec2 underline_offset = vec2(cell_size.x, cell_size.y - (glyph_baseline / 2));

        // Go to the bottom of the cell, take away the size of the
        // underline, and that is our position. We also float it slightly
        // above the bottom.
        cell_pos = cell_pos + underline_offset - underline_size * position;

        gl_Position = projection * vec4(cell_pos, 0.0, 1.0);
        color = fg_color_in / 255.0;
        break;
    }
}
