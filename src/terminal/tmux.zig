//! Types and functions related to tmux protocols.
//!
//! ROOTSHELL-TMUX: fork-owned aggregator. The module symbol stays `terminal.tmux`
//! (so `main.zig`'s wiring line is byte-identical to upstream and never conflicts),
//! but the implementation files were relocated out of the upstream-shared
//! `src/terminal/tmux/` path into the fork-owned `src/terminal/tmux_cc/` path so
//! upstream's experimental tmux parser can never 3-way-merge against ours.
//! On rebase: always take OUR version of this file (the import paths below).
//! See docs/tmux-control-mode-fork.md.

const control = @import("tmux_cc/control.zig");
const layout = @import("tmux_cc/layout.zig");
pub const output = @import("tmux_cc/output.zig");
pub const ControlParser = control.Parser;
pub const ControlNotification = control.Notification;
pub const ControlWriter = @import("tmux_cc/control_writer.zig").ControlWriter;
pub const Layout = layout.Layout;
pub const Viewer = @import("tmux_cc/viewer.zig").Viewer;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tmux_cc/integration_test.zig");
}
