//! Window represents a single terminal window. A terminal window is
//! a single drawable terminal surface.
//!
//! This Window is the abstract window logic that applies to all platforms.
//! Platforms are expected to implement a compile-time "interface" to
//! implement platform-specific logic.
//!
//! Note(mitchellh): We current conflate a "window" and a "surface". If
//! we implement splits, we probably will need to separate these concepts.
pub const Window = @This();
