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
* shift-click and drag to continue selection

Mac:

* Set menubar
* Preferences window

Major Features:

* Reloadable configuration
* Bell
* Sixels: https://saitoha.github.io/libsixel/
* Kitty keyboard protocol: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
* Kitty graphics protocol: https://sw.kovidgoyal.net/kitty/graphics-protocol/
* Colored underlines: https://sw.kovidgoyal.net/kitty/underlines/
