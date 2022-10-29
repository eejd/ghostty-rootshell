using namespace metal;

struct Uniforms {
    float4x4 projection_matrix;
    float2 cell_size;
};

vertex float4 basic_vertex(
  unsigned int vid [[ vertex_id ]],
  constant Uniforms &uniforms [[ buffer(1) ]]
) {
  // Where we are in the grid (x, y) where top-left is origin
  float2 grid_coord = float2(0.0f, 0.0f);

  // Convert the grid x,y into world space x, y by accounting for cell size
  float2 cell_pos = uniforms.cell_size * grid_coord;

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
  cell_pos = cell_pos + uniforms.cell_size * position;

  return uniforms.projection_matrix * float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f);
}

fragment half4 basic_fragment() {
  return half4(1.0, 0.0, 0.0, 1.0);
}
