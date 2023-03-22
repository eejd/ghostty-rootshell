Performance:

* for scrollback, investigate using segmented list for sufficiently large
  scrollback scenarios.
* Loading fonts on startups should probably happen in multiple threads
* `deleteLines` is very, very slow which makes scroll region benchmarks terrible

Correctness:

* test wrap against wraptest: https://github.com/mattiase/wraptest
  - automate this in some way
* Charsets: UTF-8 vs. ASCII mode
  - we only support UTF-8 input right now
  - need fallback glyphs if they're not supported
  - can effect a crash using `vttest` menu `3 10` since it tries to parse
    ASCII as UTF-8.

Improvements:

* scrollback: configurable

Mac:

* Preferences window

Major Features:

* Reloadable configuration
* Bell
* Sixels: https://saitoha.github.io/libsixel/
* Kitty keyboard protocol: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
* Kitty graphics protocol: https://sw.kovidgoyal.net/kitty/graphics-protocol/
* Colored underlines: https://sw.kovidgoyal.net/kitty/underlines/
