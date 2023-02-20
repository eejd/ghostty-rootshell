//! Application runtime that uses GTK4.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const c = @cImport({
    @cInclude("gtk/gtk.h");
});

const log = std.log.scoped(.gtk);

pub const App = struct {
    pub const Options = struct {
        /// GTK app ID
        id: [:0]const u8 = "com.mitchellh.ghostty",
    };

    pub fn init(opts: Options) !App {
        const app = c.gtk_application_new(opts.id.ptr, c.G_APPLICATION_DEFAULT_FLAGS);
        errdefer c.g_object_unref(app);
        return .{};
    }

    pub fn terminate(self: App) void {
        _ = self;
    }

    pub fn wakeup(self: App) !void {
        _ = self;
    }

    pub fn wait(self: App) !void {
        _ = self;
    }
};

pub const Window = struct {
    pub const Options = struct {};

    pub fn deinit(self: *Window) void {
        _ = self;
    }
};
