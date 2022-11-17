Bugs:

* Asian characters (amongst others) turn into missing glyph symbol, should
  be able to find them somewhere when other programs can render them fine.

Performance:

* for scrollback, investigate using segmented list for sufficiently large
  scrollback scenarios.
* reflow: text reflow is really poorly implemented right now specifically
  for shrinking columns. Look into this. This may require changing the
  screen data structure.
* Loading fonts on startups should probably happen in multiple threads
* Windowing event loop should not check `shouldClose` on every window
  and should use should close callbacks instead.
* Window shutdown should be done in threads but GLFW window close cannot
  be done in multiple threads making this a bit tricky.
* `deleteLines` is very, very slow which makes scroll region benchmarks terrible

Correctness:

* `exit` in the shell should close the window
* test wrap against wraptest: https://github.com/mattiase/wraptest
  - automate this in some way
* Charsets: UTF-8 vs. ASCII mode
  - we only support UTF-8 input right now
  - need fallback glyphs if they're not supported
  - can effect a crash using `vttest` menu `3 10` since it tries to parse
    ASCII as UTF-8.

Improvements:

* scrollback: configurable
* selection on top/bottom should scroll up/down (while extending selection)
* double-click to select a word
* triple-click to select a line
* shift-click and drag to continue selection
* keybind action: increase/decrease font size

Mac:

* Set menubar
* Preferences window

Major Features:

* Reloadable configuration
* Bell
* Sixels: https://saitoha.github.io/libsixel/
* Kitty keyboard protocol: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
* Kitty graphics protocol: https://sw.kovidgoyal.net/kitty/graphics-protocol/
* Colored/styled underlines: https://sw.kovidgoyal.net/kitty/underlines/
