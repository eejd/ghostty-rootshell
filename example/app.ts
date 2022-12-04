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
  } = results.instance.exports;
  // Give us access to the zjs value for debugging.
  globalThis.zjs = zjs;
  console.log(zjs);

  // Initialize our zig-js memory
  zjs.memory = memory;

  // Create some memory for our string
  const font = new TextEncoder().encode("monospace");
  const font_ptr = malloc(font.byteLength);
  try {
    new Uint8Array(memory.buffer, font_ptr).set(font);

    // Call whatever example you want:
    const face = face_new(font_ptr, font.byteLength);
    face_free(face);
  } finally {
    free(font_ptr);
  }
});
