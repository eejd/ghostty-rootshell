Bugs:

* Underline should use freetype underline thickness hint
* Any printing action forces scroll to jump to bottom, this makes it impossible
  to scroll up while logs are coming in or something

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

* Selection, highlighting
* Copy (paste is done)
* Strikethrough
* Emoji
* Ligatures

