const std = @import("std");
const Allocator = std.mem.Allocator;

const request = @import("request.zig");
const response = @import("response.zig");
const Glossary = @import("Glossary.zig");
const Request = request.Request;
const Response = response.Response;

const log = std.log.scoped(.glyph);

/// Payload formats we support. Hardcoded because the support is
/// fixed.
pub const supported_formats: response.Response.Support.Formats = .{
    .glyf = true,
};

/// Execute a Glyph protocol request against the given state.
///
/// This will never fail, but the response may indiciate an error and
/// the terminal state may not be updated to reflect the command. This will
/// never put the terminal in a corrupt or non-recoverable state.
///
/// For example, allocation errors can happen, but they're wrapped up in
/// an out of memory response.
pub fn execute(
    alloc: Allocator,
    glossary: *Glossary,
    req: *const Request,
) ?Response {
    _ = alloc;
    _ = glossary;
    log.debug("executing glyph protocol request: {t}", .{req.*});
    return switch (req.*) {
        .support => .{ .support = .{ .fmt = supported_formats } },
        .query, .register, .clear => @panic("TODO"),
    };
}
