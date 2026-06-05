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
    log.debug("executing glyph protocol request: {t}", .{req.*});
    return switch (req.*) {
        .support => .{ .support = .{ .fmt = supported_formats } },
        .register => |reg| register(alloc, glossary, reg),
        .query, .clear => @panic("TODO"),
    };
}

fn register(
    alloc: Allocator,
    glossary: *Glossary,
    reg: Request.Register,
) ?Response {
    const reply = reg.get(.reply) orelse .all;
    const cp = registerFallible(alloc, glossary, reg) catch |err| return switch (reply) {
        .none => null,
        .all, .failures => .{ .register = .{
            .cp = reg.get(.cp) orelse 0,
            .status = .err,
            .reason = switch (err) {
                error.OutOfMemory => .{ .other = "out_of_memory" },
                error.OutOfNamespace => .out_of_namespace,
                error.PayloadTooLarge => .payload_too_large,
                error.MalformedPayload => .malformed_payload,
                error.CompositeUnsupported => .composite_unsupported,
                error.HintingUnsupported => .hinting_unsupported,
                error.InvalidOptions,
                error.UnsupportedFormat,
                => .malformed_payload,
            },
        } },
    };

    return switch (reply) {
        .none, .failures => null,
        .all => .{ .register = .{ .cp = cp } },
    };
}

fn registerFallible(
    alloc: Allocator,
    glossary: *Glossary,
    reg: Request.Register,
) (Glossary.Entry.InitError || Glossary.RegisterError)!u21 {
    const cp = reg.get(.cp) orelse
        return error.MalformedPayload;

    var entry = try Glossary.Entry.init(alloc, reg);
    errdefer entry.deinit(alloc);

    try glossary.register(alloc, cp, entry);
    return cp;
}

fn testParse(alloc: Allocator, data: []const u8) !Request {
    var parser = request.CommandParser.init(alloc, 1024 * 1024);
    defer parser.deinit();
    for (data) |byte| try parser.feed(byte);
    return try parser.complete(alloc);
}

test "execute register stores glyph and returns success" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var req = try testParse(alloc, "r;cp=e0a0;AAAAAAAAAAAAAA==");
    defer req.deinit(alloc);

    try testing.expectEqual(Response{
        .register = .{ .cp = 0xE0A0 },
    }, execute(alloc, &glossary, &req).?);
    try testing.expect(glossary.contains(0xE0A0));
}

test "execute register reply failures suppresses success" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var req = try testParse(alloc, "r;cp=e0a0;reply=2;AAAAAAAAAAAAAA==");
    defer req.deinit(alloc);

    try testing.expect(execute(alloc, &glossary, &req) == null);
    try testing.expect(glossary.contains(0xE0A0));
}

test "execute register reply none suppresses failure" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var req = try testParse(alloc, "r;cp=41;reply=0;%%%not-base64%%%");
    defer req.deinit(alloc);

    try testing.expect(execute(alloc, &glossary, &req) == null);
    try testing.expect(!glossary.contains('A'));
}

test "execute register rejects non-PUA" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var req = try testParse(alloc, "r;cp=41;AAAAAAAAAAAAAA==");
    defer req.deinit(alloc);

    try testing.expectEqual(Response{
        .register = .{
            .cp = 'A',
            .status = .err,
            .reason = .out_of_namespace,
        },
    }, execute(alloc, &glossary, &req).?);
    try testing.expect(!glossary.contains('A'));
}

test "execute register reports malformed payload" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var req = try testParse(alloc, "r;cp=e0a0;%%%not-base64%%%");
    defer req.deinit(alloc);

    try testing.expectEqual(Response{
        .register = .{
            .cp = 0xE0A0,
            .status = .err,
            .reason = .malformed_payload,
        },
    }, execute(alloc, &glossary, &req).?);
    try testing.expect(!glossary.contains(0xE0A0));
}
