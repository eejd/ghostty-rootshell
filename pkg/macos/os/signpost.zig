const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const logpkg = @import("log.zig");
const Log = logpkg.Log;

/// Checks whether signpost logging is enabled for the given log handle.
/// Returns true if signposts will be recorded for this log, false otherwise.
/// This can be used to avoid expensive operations when signpost logging is disabled.
///
/// https://developer.apple.com/documentation/os/os_signpost_enabled?language=objc
pub fn enabled(log: *Log) bool {
    return c.os_signpost_enabled(@ptrCast(log));
}

/// Emits a signpost event - a single point in time marker.
/// Events are useful for marking when specific actions occur, such as
/// user interactions, state changes, or other discrete occurrences.
/// The event will appear as a vertical line in Instruments.
///
/// https://developer.apple.com/documentation/os/os_signpost_event_emit?language=objc
pub fn emitEvent(
    log: *Log,
    id: Id,
    comptime name: [:0]const u8,
) void {
    emitWithName(log, id, .event, name);
}

/// Marks the beginning of a time interval.
/// Use this with intervalEnd to measure the duration of operations.
/// The same ID must be used for both the begin and end calls.
/// Intervals appear as horizontal bars in Instruments timeline.
///
/// https://developer.apple.com/documentation/os/os_signpost_interval_begin?language=objc
pub fn intervalBegin(log: *Log, id: Id, comptime name: [:0]const u8) void {
    emitWithName(log, id, .interval_begin, name);
}

/// Marks the end of a time interval.
/// Must be paired with a prior intervalBegin call using the same ID.
/// The name should match the name used in intervalBegin.
/// Instruments will calculate and display the duration between begin and end.
///
/// https://developer.apple.com/documentation/os/os_signpost_interval_end?language=objc
pub fn intervalEnd(log: *Log, id: Id, comptime name: [:0]const u8) void {
    emitWithName(log, id, .interval_end, name);
}

extern var __dso_handle: usize;

/// The internal function to emit a signpost with a specific name.
fn emitWithName(
    log: *Log,
    id: Id,
    typ: Type,
    comptime name: [:0]const u8,
) void {
    var buf: [64]u8 = @splat(0);
    c._os_signpost_emit_with_name_impl(
        &__dso_handle,
        @ptrCast(log),
        @intFromEnum(typ),
        @intFromEnum(id),
        name.ptr,
        null,
        &buf,
        buf.len,
    );
}

/// https://developer.apple.com/documentation/os/os_signpost_id_t?language=objc
pub const Id = enum(u64) {
    null = 0, // OS_SIGNPOST_ID_NULL
    invalid = 0xFFFFFFFFFFFFFFFF, // OS_SIGNPOST_ID_INVALID
    exclusive = 0xEEEEB0B5B2B2EEEE, // OS_SIGNPOST_ID_EXCLUSIVE
    _,

    /// Generates a new signpost ID for use with signpost operations.
    /// The ID is unique for the given log handle and can be used to track
    /// asynchronous operations or mark specific points of interest in the code.
    /// Returns a unique signpost ID that can be used with os_signpost functions.
    ///
    /// https://developer.apple.com/documentation/os/os_signpost_id_generate?language=objc
    pub fn generate(log: *Log) Id {
        return @enumFromInt(c.os_signpost_id_generate(@ptrCast(log)));
    }

    /// Creates a signpost ID based on a pointer value.
    /// This is useful for tracking operations associated with a specific object
    /// or memory location. The same pointer will always generate the same ID
    /// for a given log handle, allowing correlation of signpost events.
    /// Pass null to get the null signpost ID.
    ///
    /// https://developer.apple.com/documentation/os/os_signpost_id_for_pointer?language=objc
    pub fn forPointer(log: *Log, ptr: ?*anyopaque) Id {
        return @enumFromInt(c.os_signpost_id_make_with_pointer(
            @ptrCast(log),
            @ptrCast(ptr),
        ));
    }

    test "generate ID" {
        // We can't really test the return value because it may return null
        // if signposts are disabled.
        const id: Id = .generate(Log.create("com.mitchellh.ghostty", "test"));
        try std.testing.expect(id != .invalid);
    }

    test "generate ID for pointer" {
        var foo: usize = 0x1234;
        const id: Id = .forPointer(Log.create("com.mitchellh.ghostty", "test"), &foo);
        try std.testing.expect(id != .null);
    }
};

/// https://developer.apple.com/documentation/os/ossignposttype?language=objc
pub const Type = enum(u8) {
    event = 0, // OS_SIGNPOST_EVENT
    interval_begin = 1, // OS_SIGNPOST_INTERVAL_BEGIN
    interval_end = 2, // OS_SIGNPOST_INTERVAL_END

    pub const mask: u8 = 0x03; // OS_SIGNPOST_TYPE_MASK
};

/// Special os_log category values that surface in Instruments and other
/// tooling.
pub const Category = struct {
    /// Points of Interest appear as a dedicated track in Instruments.
    /// Use this for high-level application events that help understand
    /// the flow of your application.
    pub const points_of_interest: [:0]const u8 = "PointsOfInterest";

    /// Dynamic Tracing category enables runtime-configurable logging.
    /// Signposts in this category can be enabled/disabled dynamically
    /// without recompiling.
    pub const dynamic_tracing: [:0]const u8 = "DynamicTracking";

    /// Dynamic Stack Tracing category captures call stacks at signpost
    /// events. This provides deeper debugging information but has higher
    /// performance overhead.
    pub const dynamic_stack_tracing: [:0]const u8 = "DynamicStackTracking";
};

test {
    _ = Id;
}

test enabled {
    _ = enabled(Log.create("com.mitchellh.ghostty", "test"));
}

test "intervals" {
    const log = Log.create("com.mitchellh.ghostty", "test");
    defer log.release();

    // Test that we can begin and end an interval
    const id = Id.generate(log);
    intervalBegin(log, id, "Test Interval");
}
