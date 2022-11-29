//! This file contains helpers for wasm compilation.
const std = @import("std");

/// The allocator to use in wasm environments.
pub const alloc = std.heap.page_allocator;
