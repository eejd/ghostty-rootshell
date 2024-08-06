using namespace metal;

struct Uniforms {
  float4x4 projection_matrix;
  float2 cell_size;
  ushort2 grid_size;
  float4 grid_padding;
  bool padding_extend_top;
  bool padding_extend_bottom;
  float min_contrast;
  ushort2 cursor_pos;
  uchar4 cursor_color;
};

//-------------------------------------------------------------------
// Color Functions
//-------------------------------------------------------------------
#pragma mark - Colors

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#relativeluminancedef
float luminance_component(float c) {
  if (c <= 0.03928f) {
    return c / 12.92f;
  } else {
    return pow((c + 0.055f) / 1.055f, 2.4f);
  }
}

float relative_luminance(float3 color) {
  color.r = luminance_component(color.r);
  color.g = luminance_component(color.g);
  color.b = luminance_component(color.b);
  float3 weights = float3(0.2126f, 0.7152f, 0.0722f);
  return dot(color, weights);
}

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#contrast-ratiodef
float contrast_ratio(float3 color1, float3 color2) {
  float l1 = relative_luminance(color1);
  float l2 = relative_luminance(color2);
  return (max(l1, l2) + 0.05f) / (min(l1, l2) + 0.05f);
}

// Return the fg if the contrast ratio is greater than min, otherwise
// return a color that satisfies the contrast ratio. Currently, the color
// is always white or black, whichever has the highest contrast ratio.
float4 contrasted_color(float min, float4 fg, float4 bg) {
  float3 fg_premult = fg.rgb * fg.a;
  float3 bg_premult = bg.rgb * bg.a;
  float ratio = contrast_ratio(fg_premult, bg_premult);
  if (ratio < min) {
    float white_ratio = contrast_ratio(float3(1.0f), bg_premult);
    float black_ratio = contrast_ratio(float3(0.0f), bg_premult);
    if (white_ratio > black_ratio) {
      return float4(1.0f);
    } else {
      return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }
  }

  return fg;
}

//-------------------------------------------------------------------
// Cell Background Shader
//-------------------------------------------------------------------
#pragma mark - Cell BG Shader

// The possible modes that a cell bg entry can take.
enum CellBgMode : uint8_t {
  MODE_RGB = 1u,
};

struct CellBgVertexIn {
  // The mode for this cell.
  uint8_t mode [[attribute(0)]];

  // The grid coordinates (x, y) where x < columns and y < rows
  ushort2 grid_pos [[attribute(1)]];

  // The color. For BG modes, this is the bg color, for FG modes this is
  // the text color. For styles, this is the color of the style.
  uchar4 color [[attribute(3)]];

  // The width of the cell in cells (i.e. 2 for double-wide).
  uint8_t cell_width [[attribute(2)]];
};

struct CellBgVertexOut {
  float4 position [[position]];
  float4 color;
};

vertex CellBgVertexOut cell_bg_vertex(unsigned int vid [[vertex_id]],
                                      CellBgVertexIn input [[stage_in]],
                                      constant Uniforms& uniforms
                                      [[buffer(1)]]) {
  // Convert the grid x,y into world space x, y by accounting for cell size
  float2 cell_pos = uniforms.cell_size * float2(input.grid_pos);

  // Scaled cell size for the cell width
  float2 cell_size_scaled = uniforms.cell_size;
  cell_size_scaled.x = cell_size_scaled.x * input.cell_width;

  // If we're at the edge of the grid, we add our padding to the background
  // to extend it. Note: grid_padding is top/right/bottom/left. We always
  // extend horiziontally because there is no downside but there are various
  // heuristics to disable vertical extension.
  if (input.grid_pos.y == 0 && uniforms.padding_extend_top) {
    cell_pos.y -= uniforms.grid_padding.r;
    cell_size_scaled.y += uniforms.grid_padding.r;
  } else if (input.grid_pos.y == uniforms.grid_size.y - 1 &&
             uniforms.padding_extend_bottom) {
    cell_size_scaled.y += uniforms.grid_padding.b;
  }
  if (input.grid_pos.x == 0) {
    cell_pos.x -= uniforms.grid_padding.a;
    cell_size_scaled.x += uniforms.grid_padding.a;
  } else if (input.grid_pos.x == uniforms.grid_size.x - 1) {
    cell_size_scaled.x += uniforms.grid_padding.g;
  }

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

  // Calculate the final position of our cell in world space.
  // We have to add our cell size since our vertices are offset
  // one cell up and to the left. (Do the math to verify yourself)
  cell_pos = cell_pos + cell_size_scaled * position;

  CellBgVertexOut out;
  out.color = float4(input.color) / 255.0f;
  out.position =
      uniforms.projection_matrix * float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f);

  return out;
}

fragment float4 cell_bg_fragment(CellBgVertexOut in [[stage_in]]) {
  return in.color;
}

//-------------------------------------------------------------------
// Cell Text Shader
//-------------------------------------------------------------------
#pragma mark - Cell Text Shader

// The possible modes that a cell fg entry can take.
enum CellTextMode : uint8_t {
  MODE_TEXT = 1u,
  MODE_TEXT_CONSTRAINED = 2u,
  MODE_TEXT_COLOR = 3u,
  MODE_TEXT_CURSOR = 4u,
  MODE_TEXT_POWERLINE = 4u,
};

struct CellTextVertexIn {
  // The mode for this cell.
  uint8_t mode [[attribute(0)]];

  // The grid coordinates (x, y) where x < columns and y < rows
  ushort2 grid_pos [[attribute(1)]];

  // The width of the cell in cells (i.e. 2 for double-wide).
  uint8_t cell_width [[attribute(6)]];

  // The color of the rendered text glyph.
  uchar4 color [[attribute(5)]];

  // The background color of the cell. This is used to determine if
  // we need to render the text with a different color to ensure
  // contrast.
  uchar4 bg_color [[attribute(7)]];

  // The position of the glyph in the texture (x,y)
  uint2 glyph_pos [[attribute(2)]];

  // The size of the glyph in the texture (w,h)
  uint2 glyph_size [[attribute(3)]];

  // The left and top bearings for the glyph (x,y)
  int2 glyph_offset [[attribute(4)]];
};

struct CellTextVertexOut {
  float4 position [[position]];
  float2 cell_size;
  uint8_t mode;
  float4 color;
  float2 tex_coord;
};

vertex CellTextVertexOut cell_text_vertex(unsigned int vid [[vertex_id]],
                                          CellTextVertexIn input [[stage_in]],
                                          constant Uniforms& uniforms
                                          [[buffer(1)]]) {
  // Convert the grid x,y into world space x, y by accounting for cell size
  float2 cell_pos = uniforms.cell_size * float2(input.grid_pos);

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

  CellTextVertexOut out;
  out.mode = input.mode;
  out.cell_size = uniforms.cell_size;
  out.color = float4(input.color) / 255.0f;

  float2 glyph_size = float2(input.glyph_size);
  float2 glyph_offset = float2(input.glyph_offset);

  // The glyph_offset.y is the y bearing, a y value that when added
  // to the baseline is the offset (+y is up). Our grid goes down.
  // So we flip it with `cell_size.y - glyph_offset.y`.
  glyph_offset.y = cell_size_scaled.y - glyph_offset.y;

  // If we're constrained then we need to scale the glyph.
  // We also always constrain colored glyphs since we should have
  // their scaled cell size exactly correct.
  if (input.mode == MODE_TEXT_CONSTRAINED || input.mode == MODE_TEXT_COLOR) {
    if (glyph_size.x > cell_size_scaled.x) {
      float new_y = glyph_size.y * (cell_size_scaled.x / glyph_size.x);
      glyph_offset.y += (glyph_size.y - new_y) / 2;
      glyph_size.y = new_y;
      glyph_size.x = cell_size_scaled.x;
    }
  }

  // Calculate the final position of the cell which uses our glyph size
  // and glyph offset to create the correct bounding box for the glyph.
  cell_pos = cell_pos + glyph_size * position + glyph_offset;
  out.position =
      uniforms.projection_matrix * float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f);

  // Calculate the texture coordinate in pixels. This is NOT normalized
  // (between 0.0 and 1.0) and must be done in the fragment shader.
  out.tex_coord = float2(input.glyph_pos) + float2(input.glyph_size) * position;

  // If we have a minimum contrast, we need to check if we need to
  // change the color of the text to ensure it has enough contrast
  // with the background.
  // We only apply this adjustment to "normal" text with MODE_TEXT,
  // since we want color glyphs to appear in their original color
  // and Powerline glyphs to be unaffected (else parts of the line would
  // have different colors as some parts are displayed via background colors).
  if (uniforms.min_contrast > 1.0f && input.mode == MODE_TEXT) {
    float4 bg_color = float4(input.bg_color) / 255.0f;
    out.color = contrasted_color(uniforms.min_contrast, out.color, bg_color);
  }

  // If this cell is the cursor cell, then we need to change the color.
  if (input.mode != MODE_TEXT_CURSOR &&
      input.grid_pos.x == uniforms.cursor_pos.x &&
      input.grid_pos.y == uniforms.cursor_pos.y) {
    out.color = float4(uniforms.cursor_color) / 255.0f;
  }

  return out;
}

fragment float4 cell_text_fragment(CellTextVertexOut in [[stage_in]],
                                   texture2d<float> textureGreyscale
                                   [[texture(0)]],
                                   texture2d<float> textureColor
                                   [[texture(1)]]) {
  constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);

  switch (in.mode) {
    case MODE_TEXT_CURSOR:
    case MODE_TEXT_CONSTRAINED:
    case MODE_TEXT_POWERLINE:
    case MODE_TEXT: {
      // Normalize the texture coordinates to [0,1]
      float2 size =
          float2(textureGreyscale.get_width(), textureGreyscale.get_height());
      float2 coord = in.tex_coord / size;

      // We premult the alpha to our whole color since our blend function
      // uses One/OneMinusSourceAlpha to avoid blurry edges.
      // We first premult our given color.
      float4 premult = float4(in.color.rgb * in.color.a, in.color.a);
      // Then premult the texture color
      float a = textureGreyscale.sample(textureSampler, coord).r;
      premult = premult * a;
      return premult;
    }

    case MODE_TEXT_COLOR: {
      // Normalize the texture coordinates to [0,1]
      float2 size = float2(textureColor.get_width(), textureColor.get_height());
      float2 coord = in.tex_coord / size;
      return textureColor.sample(textureSampler, coord);
    }
  }
}
//-------------------------------------------------------------------
// Image Shader
//-------------------------------------------------------------------
#pragma mark - Image Shader

struct ImageVertexIn {
  // The grid coordinates (x, y) where x < columns and y < rows where
  // the image will be rendered. It will be rendered from the top left.
  float2 grid_pos [[attribute(1)]];

  // Offset in pixels from the top-left of the cell to make the top-left
  // corner of the image.
  float2 cell_offset [[attribute(2)]];

  // The source rectangle of the texture to sample from.
  float4 source_rect [[attribute(3)]];

  // The final width/height of the image in pixels.
  float2 dest_size [[attribute(4)]];
};

struct ImageVertexOut {
  float4 position [[position]];
  float2 tex_coord;
};

vertex ImageVertexOut image_vertex(unsigned int vid [[vertex_id]],
                                   ImageVertexIn input [[stage_in]],
                                   texture2d<uint> image [[texture(0)]],
                                   constant Uniforms& uniforms [[buffer(1)]]) {
  // The size of the image in pixels
  float2 image_size = float2(image.get_width(), image.get_height());

  // Turn the image position into a vertex point depending on the
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

  // The texture coordinates start at our source x/y, then add the width/height
  // as enabled by our instance id, then normalize to [0, 1]
  float2 tex_coord = input.source_rect.xy;
  tex_coord += input.source_rect.zw * position;
  tex_coord /= image_size;

  ImageVertexOut out;

  // The position of our image starts at the top-left of the grid cell and
  // adds the source rect width/height components.
  float2 image_pos = (uniforms.cell_size * input.grid_pos) + input.cell_offset;
  image_pos += input.dest_size * position;

  out.position =
      uniforms.projection_matrix * float4(image_pos.x, image_pos.y, 0.0f, 1.0f);
  out.tex_coord = tex_coord;
  return out;
}

fragment float4 image_fragment(ImageVertexOut in [[stage_in]],
                               texture2d<uint> image [[texture(0)]]) {
  constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);

  // Ehhhhh our texture is in RGBA8Uint but our color attachment is
  // BGRA8Unorm. So we need to convert it. We should really be converting
  // our texture to BGRA8Unorm.
  uint4 rgba = image.sample(textureSampler, in.tex_coord);

  // Convert to float4 and premultiply the alpha. We should also probably
  // premultiply the alpha in the texture.
  float4 result = float4(rgba) / 255.0f;
  result.rgb *= result.a;
  return result;
}

//-------------------------------------------------------------------
// Post Shader
//-------------------------------------------------------------------
#pragma mark - Post Shader

struct PostVertexOut {
  float4 position [[position]];
};

constant float2 post_pos[4] = {{-1, -1}, {1, -1}, {-1, 1}, {1, 1}};

vertex PostVertexOut post_vertex(uint id [[vertex_id]]) {
  PostVertexOut out;
  out.position = float4(post_pos[id], 0, 1);
  return out;
}
