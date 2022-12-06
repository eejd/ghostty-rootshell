import { ZigJS } from 'zig-js';

const zjs = new ZigJS();
const importObject = {
  module: {},
  env: {
    log: (ptr: number, len: number) => {
      const view = new DataView(zjs.memory.buffer, ptr, Number(len));
      const str = new TextDecoder('utf-8').decode(view);
      console.log(str);
    },
  },

  ...zjs.importObject(),
};

const url = new URL('ghostty-wasm.wasm', import.meta.url);
fetch(url.href).then(response =>
  response.arrayBuffer()
).then(bytes =>
  WebAssembly.instantiate(bytes, importObject)
).then(results => {
  const {
    memory,
    malloc,
    free,
    face_new,
    face_free,
    face_render_glyph,
    face_debug_canvas,
    deferred_face_new,
    deferred_face_free,
    deferred_face_load,
    deferred_face_face,
    group_new,
    group_free,
    group_add_face,
    group_index_for_codepoint,
    group_render_glyph,
    atlas_new,
    atlas_free,
    atlas_debug_canvas,
  } = results.instance.exports;
  // Give us access to the zjs value for debugging.
  globalThis.zjs = zjs;
  console.log(zjs);

  // Initialize our zig-js memory
  zjs.memory = memory;

  // Create our atlas
  const atlas = atlas_new(512, 0 /* greyscale */);

  // Create some memory for our string
  const font = new TextEncoder().encode("monospace");
  const font_ptr = malloc(font.byteLength);
    new Uint8Array(memory.buffer, font_ptr).set(font);

  // Initialize our deferred face
  const df = deferred_face_new(font_ptr, font.byteLength);
  //deferred_face_load(df, 72 /* size */);
  //const face = deferred_face_face(df);

  // Initialize our font face
  //const face = face_new(font_ptr, font.byteLength, 72 /* size in px */);
  free(font_ptr);

  // Create our group
  const group = group_new(72 /* size */);
  group_add_face(group, 0, df);

  // Render a glyph
  for (let i = 33; i <= 126; i++) {
    const font_idx = group_index_for_codepoint(group, i, 0, -1);
    group_render_glyph(group, atlas, font_idx, i, 0);
    //face_render_glyph(face, atlas, i);
  }
  //face_render_glyph(face, atlas, "橋".codePointAt(0));
  //face_render_glyph(face, atlas, "p".codePointAt(0));

  // Debug our canvas
  //face_debug_canvas(face);

  // Debug our atlas canvas
  const id = atlas_debug_canvas(atlas);
  document.getElementById("atlas-canvas").append(zjs.deleteValue(id));

    //face_free(face);
});
