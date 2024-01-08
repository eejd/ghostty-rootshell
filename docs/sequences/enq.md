# Enquiry (Answerback)

|      |        |
| ---- | ------ |
| Text |        |
| Hex  | `0x05` |

Sends an answerback string. In the VT100, this was configurable by the
operator.

## Implementation Details

The answerback can be configured in the config file using the `enquiry-string`
configuration setting or on the command line using the `--enquiry-string`
parameter. The default is to send an empty string (`""`).

## References

- https://vt100.net/docs/vt100-ug/chapter3.html
