//! Application runtime for the embedded version of Ghostty. The embedded
//! version is when Ghostty is embedded within a parent host application,
//! rather than owning the application lifecycle itself. This is used for
//! example for the macOS build of Ghostty so that we can use a native
//! Swift+XCode-based application.

pub const App = struct {
    /// Because we only expect the embedding API to be used in embedded
    /// environments, the options are extern so that we can expose it
    /// directly to a C callconv and not pay for any translation costs.
    ///
    /// C type: ghostty_runtime_config_s
    pub const Options = extern struct {
        /// Userdata that is passed to all the callbacks.
        userdata: ?*anyopaque = null,

        /// Callback called to wakeup the event loop. This should trigger
        /// a full tick of the app loop.
        wakeup: *const fn (?*anyopaque) callconv(.C) void,
    };

    pub fn init(_: Options) !App {
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
    pub fn deinit(self: *Window) void {
        _ = self;
    }
};
