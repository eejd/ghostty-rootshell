//! Kitty graphics protocol support.
//!
//! Documentation:
//! https://sw.kovidgoyal.net/kitty/graphics-protocol
//!
//! Unimplemented features that are still todo:
//! - shared memory transmit
//! - virtual placement w/ unicode
//! - animation

pub usingnamespace @import("graphics_command.zig");
pub usingnamespace @import("graphics_exec.zig");
pub usingnamespace @import("graphics_image.zig");
pub usingnamespace @import("graphics_storage.zig");
