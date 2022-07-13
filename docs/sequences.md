# Control and Escape Sequences

This is the list of control and escape sequences known in the ecosystem
of terminal emulators and their implementation status in ghostty. Note that
some control sequences may never be implemented in ghostty. In these scenarios,
it is noted why.

Status meanings:

  * ✅ - Implementation is complete and considered 100% accurate.
  * ⚠️  - Implementation works, but may be missing some functionality. The
    details of how well it works or doesn't are in the linked page.
  * ❌ - Implementation is effectively non-functional, but ghostty continues
    in the face of it (probably in some broken state).
  * 💥 - Ghostty crashes if this control sequence is sent.

| Seq | ASCII | Name | Status |
|:---:|:-----:|:-----|:------:|
| `ENQ` | `0x05` | [Enquiry](sequences/enq.md) | ✅ |
| `BEL` | `0x07` | [Bell](sequences/bel.md) | ❌ |
| `BS` | `0x08` | [Backspace](sequences/bs.md) | ⚠️ |
