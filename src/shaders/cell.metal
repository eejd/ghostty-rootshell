using namespace metal;

// The possible modes that a shader can take.
enum Mode : uint8_t {
    MODE_BG = 1u,
    MODE_FG = 2u,
    MODE_FG_COLOR = 7u,
    MODE_CURSOR_RECT = 3u,
    MODE_CURSOR_RECT_HOLLOW = 4u,
    MODE_CURSOR_BAR = 5u,
    MODE_UNDERLINE = 6u,
    MODE_STRIKETHROUGH = 8u,
};

struct Uniforms {
  float4x4 projection_matrix;
  float2 cell_size;
  float underline_position;
  float underline_thickness;
  float strikethrough_position;
  float strikethrough_thickness;
};

struct VertexIn {
  // The mode for this cell.
  uint8_t mode [[ attribute(0) ]];

  // The grid coordinates (x, y) where x < columns and y < rows
  float2 grid_pos [[ attribute(1) ]];

  // The width of the cell in cells (i.e. 2 for double-wide).
  uint8_t cell_width [[ attribute(6) ]];

  // The color. For BG modes, this is the bg color, for FG modes this is
  // the text color. For styles, this is the color of the style.
  uchar4 color [[ attribute(5) ]];

  // The fields below are present only when rendering text.

  // The position of the glyph in the texture (x,y)
  uint2 glyph_pos [[ attribute(2) ]];

  // The size of the glyph in the texture (w,h)
  uint2 glyph_size [[ attribute(3) ]];

  // The left and top bearings for the glyph (x,y)
  int2 glyph_offset [[ attribute(4) ]];
};

struct VertexOut {
  float4 position [[ position ]];
  float2 cell_size;
  uint8_t mode;
  float4 color;
  float2 tex_coord;
};

vertex VertexOut uber_vertex(
  unsigned int vid [[ vertex_id ]],
  VertexIn input [[ stage_in ]],
  constant Uniforms &uniforms [[ buffer(1) ]]
) {
  // Convert the grid x,y into world space x, y by accounting for cell size
  float2 cell_pos = uniforms.cell_size * input.grid_pos;

  // Scaled cell size for the cell width
  float2 cell_size_scaled = uniforms.cell_size;
  cell_size_scaled.x = cell_size_scaled.x * input.cell_width;

  // Turn the cell position into a vertex point depending on the
  // vertex ID. Since we use instanced drawing, we have 4 vertices
  // for each corner of the cell. We can use vertex ID to determine
  // which one we're looking at. Using this, we can use 1 or 0 to keep
  // or discard the value for the vertex.
  //
  // 0 = top-right
  // 1 = bot-right
  // 2 = bot-left
  // 3 = top-left
  float2 position;
  position.x = (vid == 0 || vid == 1) ? 1.0f : 0.0f;
  position.y = (vid == 0 || vid == 3) ? 0.0f : 1.0f;

  VertexOut out;
  out.mode = input.mode;
  out.cell_size = uniforms.cell_size;
  out.color = float4(input.color) / 255.0f;
  switch (input.mode) {
  case MODE_BG:
    // Calculate the final position of our cell in world space.
    // We have to add our cell size since our vertices are offset
    // one cell up and to the left. (Do the math to verify yourself)
    cell_pos = cell_pos + cell_size_scaled * position;

    out.position = uniforms.projection_matrix * float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f);
    break;

  case MODE_FG:
  case MODE_FG_COLOR: {
    float2 glyph_size = float2(input.glyph_size);
    float2 glyph_offset = float2(input.glyph_offset);

    // If the glyph is larger than our cell, we need to downsample it.
    // The "+ 3" here is to give some wiggle room for fonts that are
    // BARELY over it.
    float2 glyph_size_downsampled = glyph_size;
    if (glyph_size_downsampled.y > cell_size_scaled.y + 2) {
      // Magic 0.9 and 1.1 are padding to make emoji look better
      glyph_size_downsampled.y = cell_size_scaled.y * 0.9;
      glyph_size_downsampled.x = glyph_size.x * (glyph_size_downsampled.y / glyph_size.y);
      glyph_offset.y = glyph_offset.y * 1.1 * (glyph_size_downsampled.y / glyph_size.y);
    }

    // The glyph_offset.y is the y bearing, a y value that when added
    // to the baseline is the offset (+y is up). Our grid goes down.
    // So we flip it with `cell_size.y - glyph_offset.y`.
    glyph_offset.y = cell_size_scaled.y - glyph_offset.y;

    // Calculate the final position of the cell which uses our glyph size
    // and glyph offset to create the correct bounding box for the glyph.
    cell_pos = cell_pos + glyph_size_downsampled * position + glyph_offset;
    out.position = uniforms.projection_matrix * float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f);

    // Calculate the texture coordinate in pixels. This is NOT normalized
    // (between 0.0 and 1.0) and must be done in the fragment shader.
    out.tex_coord = float2(input.glyph_pos) + float2(input.glyph_size) * position;
    break;
  }

  case MODE_CURSOR_RECT:
    // Same as background since we're taking up the whole cell.
    cell_pos = cell_pos + cell_size_scaled * position;

    out.position = uniforms.projection_matrix * float4(cell_pos, 0.0f, 1.0);
    break;

  case MODE_CURSOR_RECT_HOLLOW:
    // Top-left position of this cell is needed for the hollow rect.
    out.tex_coord = cell_pos;

    // Same as background since we're taking up the whole cell.
    cell_pos = cell_pos + cell_size_scaled * position;
    out.position = uniforms.projection_matrix * float4(cell_pos, 0.0f, 1.0);
    break;

  case MODE_CURSOR_BAR: {
    // Make the bar a smaller version of our cell
    float2 bar_size = float2(uniforms.cell_size.x * 0.2, uniforms.cell_size.y);

    // Same as background since we're taking up the whole cell.
    cell_pos = cell_pos + bar_size * position;

    out.position = uniforms.projection_matrix * float4(cell_pos, 0.0f, 1.0);
    break;
  }

  case MODE_UNDERLINE: {
    // Underline Y value is just our thickness
    float2 underline_size = float2(cell_size_scaled.x, uniforms.underline_thickness);

    // Position the underline where we are told to
    float2 underline_offset = float2(cell_size_scaled.x, uniforms.underline_position);

    // Go to the bottom of the cell, take away the size of the
    // underline, and that is our position. We also float it slightly
    // above the bottom.
    cell_pos = cell_pos + underline_offset - (underline_size * position);

    out.position = uniforms.projection_matrix * float4(cell_pos, 0.0f, 1.0);
    break;
  }

  case MODE_STRIKETHROUGH: {
    // Strikethrough Y value is just our thickness
    float2 strikethrough_size = float2(cell_size_scaled.x, uniforms.strikethrough_thickness);

    // Position the strikethrough where we are told to
    float2 strikethrough_offset = float2(cell_size_scaled.x, uniforms.strikethrough_position);

    // Go to the bottom of the cell, take away the size of the
    // strikethrough, and that is our position. We also float it slightly
    // above the bottom.
    cell_pos = cell_pos + strikethrough_offset - (strikethrough_size * position);

    out.position = uniforms.projection_matrix * float4(cell_pos, 0.0f, 1.0);
    break;
  }

  }

  return out;
}

fragment float4 uber_fragment(
  VertexOut in [[ stage_in ]],
  texture2d<float> textureGreyscale [[ texture(0) ]],
  texture2d<float> textureColor [[ texture(1) ]]
) {
  constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);

  switch (in.mode) {
  case MODE_BG:
    return in.color;

  case MODE_FG: {
    // Normalize the texture coordinates to [0,1]
    float2 size = float2(textureGreyscale.get_width(), textureGreyscale.get_height());
    float2 coord = in.tex_coord / size;

    float a = textureGreyscale.sample(textureSampler, coord).r;
    return float4(in.color.rgb, in.color.a * a);
  }

  case MODE_FG_COLOR: {
    // Normalize the texture coordinates to [0,1]
    float2 size = float2(textureColor.get_width(), textureColor.get_height());
    float2 coord = in.tex_coord / size;
    return textureColor.sample(textureSampler, coord);
  }

  case MODE_CURSOR_RECT:
    return in.color;

  case MODE_CURSOR_RECT_HOLLOW: {
    // Okay so yeah this is probably horrendously slow and a shader
    // should never do this, but we only ever render a cursor for ONE
    // rectangle so we take the slowdown for that one.

    // We subtracted one from cell size because our coordinates start at 0.
    // So a width of 50 means max pixel of 49.
    float2 cell_size_coords = in.cell_size - 1;

    // Apply padding
    float2 padding = float2(1.0f, 1.0f);
    cell_size_coords = cell_size_coords - (padding * 2);
    float2 screen_cell_pos_padded = in.tex_coord + padding;

    // Convert our frag coord to offset of this cell. We have to subtract
    // 0.5 because the frag coord is in center pixels.
    float2 cell_frag_coord = in.position.xy - screen_cell_pos_padded - 0.5;

    // If the frag coords are in the bounds, then we color it.
    const float eps = 0.1;
    if (cell_frag_coord.x >= 0 && cell_frag_coord.y >= 0 &&
        cell_frag_coord.x <= cell_size_coords.x &&
        cell_frag_coord.y <= cell_size_coords.y) {
      if (abs(cell_frag_coord.x) < eps ||
            abs(cell_frag_coord.x - cell_size_coords.x) < eps ||
            abs(cell_frag_coord.y) < eps ||
            abs(cell_frag_coord.y - cell_size_coords.y) < eps) {
        return in.color;
      }
    }

    // Default to no color.
    return float4(0.0f);
  }

  case MODE_CURSOR_BAR:
    return in.color;

  case MODE_UNDERLINE:
    return in.color;

  case MODE_STRIKETHROUGH:
    return in.color;
  }
}
