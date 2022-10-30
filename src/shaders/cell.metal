using namespace metal;

// The possible modes that a shader can take.
enum Mode : uint8_t {
    MODE_BG = 1u,
    MODE_FG = 2u,
};

struct Uniforms {
  float4x4 projection_matrix;
  float2 cell_size;
};

struct VertexIn {
  // The mode for this cell.
  uint8_t mode [[ attribute(0) ]];

  // The grid coordinates (x, y) where x < columns and y < rows
  float2 grid_pos [[ attribute(1) ]];

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
};

vertex VertexOut uber_vertex(
  unsigned int vid [[ vertex_id ]],
  VertexIn input [[ stage_in ]],
  constant Uniforms &uniforms [[ buffer(1) ]]
) {
  // Convert the grid x,y into world space x, y by accounting for cell size
  float2 cell_pos = uniforms.cell_size * input.grid_pos;

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

  // TODO: scale
  float2 cell_size = uniforms.cell_size;

  VertexOut out;
  switch (input.mode) {
  case MODE_BG:
    // Calculate the final position of our cell in world space.
    // We have to add our cell size since our vertices are offset
    // one cell up and to the left. (Do the math to verify yourself)
    cell_pos = cell_pos + uniforms.cell_size * position;

    out.position = uniforms.projection_matrix * float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f);
    break;

  case MODE_FG:
    float2 glyph_size = float2(input.glyph_size);
    float2 glyph_offset = float2(input.glyph_offset);

    // TODO: downsampling

    // The glyph_offset.y is the y bearing, a y value that when added
    // to the baseline is the offset (+y is up). Our grid goes down.
    // So we flip it with `cell_size.y - glyph_offset.y`.
    glyph_offset.y = cell_size.y - glyph_offset.y;

    // Calculate the final position of the cell.
    cell_pos = cell_pos + glyph_size * position + glyph_offset;

    out.position = uniforms.projection_matrix * float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f);
    break;
  }

  return out;
}

fragment half4 uber_fragment(
  VertexOut in [[ stage_in ]]
) {
  return half4(1.0, 0.0, 0.0, 1.0);
}
