Bugs:

* Underline should use freetype underline thickness hint

Performance:

* libuv allocates on every read, we should use a read buffer pool
* update cells should only update the changed cells
* for scrollback, investigate using segmented list for sufficiently large
  scrollback scenarios.
* scrollback: dynamic growth rather than prealloc

Correctness:

* `exit` in the shell should close the window
* scrollback: reflow on resize
* test wrap against wraptest: https://github.com/mattiase/wraptest
  - automate this in some way

Visual:

* bell

Improvements:

* scrollback: configurable

Major Features:

* Line wrap
* Selection, highlighting
* Copy (paste is done)
* Strikethrough
* Emoji
* Ligatures

