# Kitty DnD Parser — Walkthrough

A line-by-line walkthrough of the OSC 72 (kitty drag and drop protocol)
parser added to ghostty.

## Big picture: how ghostty parses OSC

Before any of these changes, ghostty's OSC handling looked like this:

1. **`src/terminal/Parser.zig`** is the VT escape sequence parser. When it
   sees `ESC ]` (OSC start), it begins feeding characters to an OSC
   sub-parser.
2. **`src/terminal/osc.zig`** holds that sub-parser. It's a character-level
   state machine that walks the digits of the OSC number (so `5522`
   advances through states `@"5"` → `@"55"` → `@"552"` → `@"5522"`), then
   captures the trailing data after the first `;`.
3. When the OSC terminator (`ST` or `BEL`) arrives, `Parser.end()`
   dispatches to one of the helpers in **`src/terminal/osc/parsers/`** based
   on the final state. Those helpers turn the raw captured bytes into a
   typed `Command` variant.
4. **`src/terminal/stream.zig`** receives the final `Command` and decides
   what handler to call (set window title, write to clipboard, etc.).
   Unimplemented commands just get a debug log.

The job here was to plug OSC 72 into this pipeline. The user-visible
result: when a TUI app sends `OSC 72 ; t=a:i=5 ; text/plain text/uri-list
ST`, ghostty parses it and produces a `Command.kitty_dnd_protocol` value
with `metadata="t=a:i=5"` and `payload="text/plain text/uri-list"`. The
actual action — actually accepting drops — is **not** wired yet.

Four files were touched. Each is walked through below.

---

## File 1: `src/terminal/osc/parsers/kitty_dnd_protocol.zig` (new, ~155 lines)

This is the bulk of the work. It's modeled directly on the existing
`kitty_clipboard_protocol.zig`.

### Imports

```zig
const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const Terminator = @import("../../osc.zig").Terminator;
```

- `std`: Zig stdlib.
- `inlineAssert`: ghostty's own assert helper from `src/quirks.zig`
  (probably wraps `std.debug.assert` with some compile-time behavior
  tuning). Used to assert the parser state matches what's expected.
- `Parser`, `Command`, `Terminator`: types from the parent `osc.zig`. This
  is a leaf parser, so these aren't defined here — we hand back data the
  parent uses.

### `pub const OSC = struct` (the output value)

```zig
pub const OSC = struct {
    metadata: []const u8,
    payload: ?[]const u8,
    terminator: Terminator,
    pub fn readOption(self: OSC, comptime key: Option) ?key.Type() {
        return key.read(self.metadata);
    }
};
```

This is what gets stored in the `Command` union when an OSC 72 is parsed.
Three fields:

- **`metadata`**: the raw bytes between the first and second `;`. For
  `OSC 72;t=m:x=5:y=3;text/plain ST`, this is `"t=m:x=5:y=3"`. Not
  pre-parsed — kept as a slice into the capture buffer.
- **`payload`**: an *optional* slice of everything after the second `;`.
  Optional because some OSCs have no payload at all (`OSC 72;t=A ST` —
  stop accepting drops, no payload needed).
- **`terminator`**: was it terminated by `ST` (`ESC \`) or `BEL` (`0x07`)?
  Recorded so when we respond, we match what the client used. This is a
  convention across all of ghostty's OSC parsers.

`readOption` is a thin wrapper around `Option.read`. It's syntactic sugar
so callers write `osc.readOption(.t)` instead of `Option.read(.t,
osc.metadata)`. The `comptime key: Option` parameter means the key is
known at compile time — that lets the return type vary per key (look at
`key.Type()`), giving you `EventType` for `.t` and `i32` for the rest.

### `pub const EventType = enum`

```zig
pub const EventType = enum {
    accept_drops,         // t=a
    stop_accepting_drops, // t=A
    drop_move,            // t=m
    drop_dropped,         // t=M
    request_data,         // t=r
    request_error,        // t=R
    offer_drag,           // t=o
    present_data,         // t=p
    change_drag_image,    // t=P
    drag_offer_event,     // t=e
    drag_offer_error,     // t=E
    uri_list_data,        // t=k
    query,                // t=q
    pub fn init(str: []const u8) ?EventType { ... }
};
```

The typed representation of the `t` metadata key — every event type the
protocol defines. There are 13 of them, mapped from single ASCII
characters (case-sensitive: `m` and `M` are different events).

`init` takes the string value of `t` (e.g. `"a"` or `"M"`), checks it's
exactly one char long, and switches on that char. Returns `null` if the
value is unknown or wrong length — null means "this key is not parseable
as EventType."

### `pub const Option = enum`

```zig
pub const Option = enum {
    t,  // event type
    m,  // chunking indicator (0 or 1)
    i,  // multiplexer id
    o,  // operation (0 reject, 1 copy, 2 move, 3 either; also reused for opacity etc.)
    x,  // cell column / 1-based index
    y,  // cell row / 1-based subindex
    X,  // pixel x / flag / handle
    Y,  // pixel y / handle / image height
    ...
};
```

The set of all metadata keys the protocol uses. **Case-sensitive**: `x`
and `X` are distinct keys with different meanings, which is one of the
protocol's subtle gotchas. Zig enum tag names are case-sensitive
identifiers, so this works naturally.

#### `pub fn Type(comptime key: Option) type`

```zig
pub fn Type(comptime key: Option) type {
    return switch (key) {
        .t => EventType,
        .m, .i, .o, .x, .y, .X, .Y => i32,
    };
}
```

A compile-time function that returns a *type*. It says: "if you ask for
the value of key `.t`, you'll get back an `EventType`; for any other key,
you'll get back an `i32`."

Why `i32`? The spec says "32-bit signed or unsigned integers". Signed was
chosen because some location keys legitimately take `-1` (e.g.
`x=-1, y=-1` means "the drag has left the window"). Using `i32` everywhere
avoids needing two types.

#### `pub fn read(comptime key: Option, metadata: []const u8) ?key.Type()`

The workhorse. Walks the `key=value:key=value:...` metadata string looking
for a specific key, returns the parsed value or null.

Step by step:

```zig
const name = @tagName(key);  // "t", "x", "X", etc.
```

`@tagName` is a Zig builtin that returns the string form of an enum tag at
compile time. For `.X` it returns `"X"`.

```zig
const value: []const u8 = value: {
    var pos: usize = 0;
    while (pos < metadata.len) {
```

A labeled block (`value: { ... }`) is used so we can `break :value <slice>`
from inside the loop. Cursor `pos` tracks where we are in the metadata.

```zig
        while (pos < metadata.len and std.ascii.isWhitespace(metadata[pos])) pos += 1;
        if (pos >= metadata.len) return null;
```

Skip any whitespace at the start of an option. The spec doesn't explicitly
require this but the clipboard parser does it and it's harmless.

```zig
        if (!std.mem.startsWith(u8, metadata[pos..], name)) {
            pos = std.mem.indexOfScalarPos(u8, metadata, pos, ':') orelse return null;
            pos += 1;
            continue;
        }
```

Try to match our key name at the current position. **Critical for this
protocol:** `std.mem.startsWith` is case-sensitive, so `"x"` will not
match `"X="`. If we don't match, jump past the next `:` to the start of
the next option. If there's no next `:`, bail (key not present).

```zig
        pos += name.len;
        while (pos < metadata.len and std.ascii.isWhitespace(metadata[pos])) pos += 1;
        if (pos >= metadata.len) return null;
        if (metadata[pos] != '=') return null;
```

The key matched. Skip past it, skip whitespace, expect `=`. If not, this
isn't actually a `key=value` pair — bail.

```zig
        const end = std.mem.indexOfScalarPos(u8, metadata, pos, ':') orelse metadata.len;
        const start = pos + 1;
        break :value std.mem.trim(u8, metadata[start..end], &std.ascii.whitespace);
```

The value runs from just after `=` to either the next `:` or end of
metadata. Trim whitespace and `break :value` with the slice. This slice
is still backed by the parser's capture buffer — no allocation.

```zig
return switch (key) {
    .t => .init(value),
    .m, .i, .o, .x, .y, .X, .Y => std.fmt.parseInt(i32, value, 10) catch null,
};
```

Once we have the value string, parse it according to the key's type. For
`.t`, hand to `EventType.init`. For integers, `std.fmt.parseInt` does the
work and returns null on garbage.

### `pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*Command`

```zig
pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*Command {
    assert(parser.state == .@"72");

    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };

    const data = cap.trailing();

    const metadata: []const u8, const payload: ?[]const u8 = result: {
        const sep = std.mem.indexOfScalar(u8, data, ';') orelse break :result .{ data, null };
        break :result .{ data[0..sep], data[sep + 1 .. data.len] };
    };

    parser.command = .{
        .kitty_dnd_protocol = .{
            .metadata = metadata,
            .payload = payload,
            .terminator = .init(terminator_ch),
        },
    };

    return &parser.command;
}
```

This is what `osc.zig` calls when it sees the OSC has finished and the
state machine is in `.@"72"`.

- `assert(parser.state == .@"72")`: sanity check — we should only ever be
  called for an OSC 72.
- Pull the capture buffer (the bytes between the OSC number and the
  terminator).
- Split on the first `;` — everything before is metadata, everything
  after is payload. If there's no `;`, the entire thing is metadata and
  payload is null.
- Stuff the result into the parser's `command` union, marking it as our
  variant.
- Return a pointer back to the union. Caller (the stream) reads it.

The destructuring syntax `const a: T1, const b: T2 = ...` is Zig's
tuple-style multiple assignment.

---

## File 2: `src/terminal/osc/parsers.zig` (1 line added)

```zig
pub const kitty_dnd_protocol = @import("parsers/kitty_dnd_protocol.zig");
```

This module is just an index — it re-exports all the parser submodules so
`osc.zig` can write `parsers.kitty_dnd_protocol.parse(...)`.

---

## File 3: `src/terminal/osc.zig` (small edits)

### Add to the `Command` union (around line ~157)

```zig
kitty_clipboard_protocol: KittyClipboardProtocol,

/// Kitty drag and drop protocol (OSC 72)
/// https://sw.kovidgoyal.net/kitty/drag-and-drop-protocol/
kitty_dnd_protocol: KittyDndProtocol,
```

`Command` is a tagged union — one variant per OSC type. A new variant is
added. Its payload type is `KittyDndProtocol`, declared right below.

### Type alias

```zig
pub const KittyClipboardProtocol = parsers.kitty_clipboard_protocol.OSC;

pub const KittyDndProtocol = parsers.kitty_dnd_protocol.OSC;
```

So the union field type has a friendly name.
`parsers.kitty_dnd_protocol.OSC` is the struct from file 1.

### Add to the `Key` enum list

```zig
"kitty_clipboard_protocol",
"kitty_dnd_protocol",
"context_signal",
```

`Key` is generated by ghostty's `LibEnum` helper, which produces an enum
from a string list (deterministic ordering for ABI stability across the
C/Zig boundary). Order matters per the comment in the file. Adding the
tag here keeps the union and the key enum in sync.

### Add to `reset()` switch

```zig
.kitty_text_sizing,
.kitty_clipboard_protocol,
.kitty_dnd_protocol,
.context_signal,
=> {},
```

`reset()` deinits any allocated memory a command variant owns. Most
variants (including this one) own no allocations — their slices point
into the parser's capture buffer, which the parser itself manages. So
this lands in the `=> {}` (do-nothing) arm. The switch must be exhaustive
across all `Key` tags, so it has to land somewhere — and "do nothing" is
correct.

### State machine — add `@"72"` and extend `@"7"`

In the `State` enum:

```zig
@"66",
@"72",
@"77",
```

In the `next()` function, extending the existing `@"7"` handler:

```zig
.@"7" => switch (c) {
    ';' => self.captureTrailing(.fixed),  // OSC 7 alone = report_pwd
    '2' => self.state = .@"72",            // NEW: OSC 72
    '7' => self.state = .@"77",            // OSC 777 bridge
    else => self.state = .invalid,
},

.@"72" => switch (c) {
    ';' => self.captureTrailing(.allocating),
    else => self.state = .invalid,
},
```

What this is doing:

- In state `@"7"` after seeing the `7` digit. If the next char is `2`,
  transition to `@"72"`. (Previously `@"7"` only accepted `;` for OSC 7
  and `7` for the OSC 77 bridge.)
- In state `@"72"`, the only valid next char is `;`, which kicks off
  **capturing** the trailing data.
- `captureTrailing(.allocating)` chooses **allocating mode** for the
  capture. The default fixed buffer is 2048 bytes, but the protocol
  allows payloads up to 4096 bytes per chunk (after base64), plus
  metadata. Allocating mode grows as needed up to whatever the allocator
  gives. If no allocator is configured, it falls back gracefully to the
  fixed buffer.

### Dispatch in `end()`

```zig
.@"66" => parsers.kitty_text_sizing.parse(self, terminator_ch),

.@"72" => parsers.kitty_dnd_protocol.parse(self, terminator_ch),

.@"77" => null,
```

When the parser sees the OSC terminator, `end()` looks at the final state
and hands off to the right helper. For state `@"72"`, that's the `parse`
function we wrote in file 1.

---

## File 4: `src/terminal/stream.zig` (added to unimplemented list)

```zig
.kitty_text_sizing,
.kitty_clipboard_protocol,
.kitty_dnd_protocol,
.context_signal,
=> {
    log.debug("unimplemented OSC callback: {}", .{cmd});
},
```

`stream.zig` is downstream of the parser — when a fully-parsed `Command`
arrives, it dispatches to a real handler (set the title, do the clipboard
op, etc.). For this protocol, there is no handler yet (intentional — that's
the next step). So it lands in the "unimplemented" arm, which just logs.

**The compiler enforces exhaustive switches**, so adding a new union
variant without adding it to this switch would have been a build error.
It had to go somewhere; this is the most honest place.

---

## Design decisions worth understanding

1. **Thin parser, lazy field reads.** Kept raw `metadata` and `payload`
   slices and provided a `readOption` accessor. Alternative: eagerly parse
   every key into a struct at parse time. The lazy approach matches
   `kitty_clipboard_protocol`, lets callers pay parse cost only for keys
   they care about, and is dead simple. Downside: every `readOption` call
   scans the metadata string. Tradeoff is fine because metadata is tiny
   (~30 chars typical).

2. **No chunking reassembly.** The protocol says payloads >4096 bytes get
   chunked across multiple OSC 72 messages. The parser deliberately does
   **not** reassemble these — each chunk surfaces as its own `Command`.
   Why: chunking is stateful across multiple escape codes, which is the
   *action layer's* concern (which buffer to append into, what to do when
   out of order, how to handle errors mid-stream). Putting that in the
   OSC parser would conflate two responsibilities.

3. **No semantic validation.** The structure is parsed but it isn't
   validated that e.g. a `t=m` event actually has a sensible `x/y`, or
   that a `t=q` query has the keys it should. The spec lets us be lax,
   and the action layer is better-positioned to validate against
   context.

4. **`i32` for all integer keys.** The spec says "32-bit signed or
   unsigned." Signed was chosen because `-1` is a real sentinel value
   (drag leave, drag cancel). Unsigned would force casting everywhere.

5. **No reset of capture in `parse`.** The parser's main loop handles
   capture lifecycle — `reset()` (in `osc.zig`) cleans up the capture
   between OSCs. The parse function just consumes `cap.trailing()` and
   returns.
