Bugs:

* Underline should use freetype underline thickness hint

Performance:

* libuv allocates on every read, we should use a read buffer pool
* update cells should only update the changed cells

Correctness:

* `exit` in the shell should close the window
* test wrap against wraptest: https://github.com/mattiase/wraptest
  - automate this in some way

Visual:

* bell

Major Features:

* History, mouse scrolling
* Line wrap
* Selection, highlighting
* Copy (paste is done)
* Strikethrough
* Emoji
* Ligatures

