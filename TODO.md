Bugs:

* Underline should use freetype underline thickness hint

Performance:

* libuv allocates on every read, we should use a read buffer pool
* update cells should only update the changed cells
* for scrollback, investigate using segmented list for sufficiently large
  scrollback scenarios.
* scrollback: dynamic growth rather than prealloc
* reflow: text reflow is really poorly implemented right now specifically
  for shrinking columns. Look into this. This may require changing the
  screen data structure.

Correctness:

* `exit` in the shell should close the window
* test wrap against wraptest: https://github.com/mattiase/wraptest
  - automate this in some way

Improvements:

* scrollback: configurable
* selection on top/bottom should scroll up/down (while extending selection)
* double-click to select a word
* triple-click to select a line
* shift-click and drag to continue selection

Major Features:

* Strikethrough
* Ligatures
* Bell
* Mac:
  - Switch to raw Cocoa and Metal instead of glfw and libuv (major!)
* Sixels: https://saitoha.github.io/libsixel/
* Kitty keyboard protocol: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
* Kitty graphics protocol: https://sw.kovidgoyal.net/kitty/graphics-protocol/
* Mouse events
* Charsets (i.e. line drawing, `CSI ( B` and so on)
