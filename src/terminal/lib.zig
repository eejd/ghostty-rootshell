const std = @import("std");
const build_options = @import("terminal_options");
const lib = @import("../lib/main.zig");

/// The target for the terminal lib in particular.
pub const target: lib.Target = if (build_options.c_abi) .c else .zig;

/// The calling convention to use for C APIs. If we're not building for
/// C ABI then we use auto which allows our C APIs to be cleanly called
/// by Zig. This is required because we modify our struct layouts based
/// on C ABI too.
pub const calling_conv: std.builtin.CallingConvention = if (build_options.c_abi)
    .c
else
    .auto;

/// Forwarded decls from lib that are used.
pub const Enum = lib.Enum;
pub const TaggedUnion = lib.TaggedUnion;
pub const Struct = lib.Struct;
pub const String = lib.String;
pub const checkGhosttyHEnum = lib.checkGhosttyHEnum;
pub const structSizedFieldFits = lib.structSizedFieldFits;
