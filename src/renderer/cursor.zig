const std = @import("std");
const terminal = @import("../terminal/main.zig");
const State = @import("State.zig");

/// Available cursor styles for drawing that renderers must support.
/// This is a superset of terminal cursor styles since the renderer supports
/// some additional cursor states such as the hollow block.
pub const CursorStyle = enum {
    block,
    block_hollow,
    bar,

    /// Create a cursor style from the terminal style request.
    pub fn fromTerminal(style: terminal.Cursor.Style) ?CursorStyle {
        return switch (style) {
            .bar => .bar,
            .block => .block,
            .underline => null, // TODO
        };
    }
};

/// Returns the cursor style to use for the current render state or null
/// if a cursor should not be rendered at all.
pub fn cursorStyle(
    state: *State,
    focused: bool,
    blink_visible: bool,
) ?CursorStyle {
    // The cursor is only at the bottom of the viewport. If we aren't
    // at the bottom, we never render the cursor.
    if (!state.terminal.screen.viewportIsBottom()) return null;

    // If we are in preedit, then we always show the cursor
    if (state.preedit != null) return .block;

    // If the cursor is explicitly not visible by terminal mode, then false.
    if (!state.terminal.modes.get(.cursor_visible)) return null;

    // If we're not focused, our cursor is always visible so that
    // we can show the hollow box.
    if (!focused) return .block_hollow;

    // If the cursor is blinking and our blink state is not visible,
    // then we don't show the cursor.
    if (state.terminal.modes.get(.cursor_blinking) and !blink_visible) {
        return null;
    }

    // Otherwise, we use whatever the terminal wants.
    return CursorStyle.fromTerminal(state.terminal.screen.cursor.style);
}
