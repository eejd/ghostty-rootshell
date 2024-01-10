# Enquiry (Answerback)

|      |        |
| ---- | ------ |
| Text |        |
| Hex  | `0x05` |

Sends an answerback string. In the VT100, this was configurable by the
operator.

## Implementation Details

The answerback can be configured in the config file using the `enquiry-response`
configuration setting or on the command line using the `--enquiry-response`
parameter. The default is to send an empty string (`""`).

## TODO

- Implement method for changing the answerback on-the-fly. This could be part of
  a larger configuration editor or as a stand-alone method.

## References

- https://vt100.net/docs/vt100-ug/chapter3.html
- https://documentation.help/PuTTY/config-answerback.html
- https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h4-Single-character-functions:ENQ.C29
- https://invisible-island.net/xterm/manpage/xterm.html#VT100-Widget-Resources:answerbackString
- https://iterm2.com/documentation-preferences-profiles-terminal.html
- https://iterm2.com/documentation-scripting.html
