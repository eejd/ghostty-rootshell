//! Build options, available at comptime. Used to configure features. This
//! will reproduce some of the fields from builtin and build_options just
//! so we can limit the amount of imports we need AND give us the ability
//! to shim logic and values into them later.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const assert = std.debug.assert;
const apprt = @import("apprt.zig");
const font = @import("font/main.zig");
const rendererpkg = @import("renderer.zig");

/// The build configuratin options. This may not be all available options
/// to `zig build` but it contains all the options that the Ghostty source
/// needs to know about at comptime.
///
/// We put this all in a single struct so that we can check compatibility
/// between options, make it easy to copy and mutate options for different
/// build types, etc.
pub const BuildConfig = struct {
    static: bool = false,
    flatpak: bool = false,
    libadwaita: bool = false,
    app_runtime: apprt.Runtime = .none,
    renderer: rendererpkg.Impl = .opengl,
    font_backend: font.Backend = .freetype,

    /// Configure the build options with our values.
    pub fn addOptions(self: BuildConfig, step: *std.Build.Step.Options) void {
        // We need to break these down individual because addOption doesn't
        // support all types.
        step.addOption(bool, "flatpak", self.flatpak);
        step.addOption(bool, "libadwaita", self.libadwaita);
        step.addOption(apprt.Runtime, "app_runtime", self.app_runtime);
        step.addOption(font.Backend, "font_backend", self.font_backend);
        step.addOption(rendererpkg.Impl, "renderer", self.renderer);
    }

    /// Rehydrate our BuildConfig from the comptime options. Note that not all
    /// options are available at comptime, so look closely at this implementation
    /// to see what is and isn't available.
    pub fn fromOptions() BuildConfig {
        return .{
            .flatpak = options.flatpak,
            .libadwaita = options.libadwaita,
            .app_runtime = std.meta.stringToEnum(apprt.Runtime, @tagName(options.app_runtime)).?,
            .font_backend = std.meta.stringToEnum(font.Backend, @tagName(options.font_backend)).?,
            .renderer = std.meta.stringToEnum(rendererpkg.Impl, @tagName(options.renderer)).?,
        };
    }
};

/// The semantic version of this build.
pub const version = options.app_version;
pub const version_string = options.app_version_string;

/// The artifact we're producing. This can be used to determine if we're
/// building a standalone exe, an embedded lib, etc.
pub const artifact = Artifact.detect();

/// Our build configuration. We re-export a lot of these back at the
/// top-level so its a bit cleaner to use throughout the code. See the doc
/// comments in BuildConfig for details on each.
pub const config = BuildConfig.fromOptions();
pub const flatpak = options.flatpak;
pub const app_runtime: apprt.Runtime = config.app_runtime;
pub const font_backend: font.Backend = config.font_backend;
pub const renderer: rendererpkg.Impl = config.renderer;

pub const Artifact = enum {
    /// Standalone executable
    exe,

    /// Embeddable library
    lib,

    /// The WASM-targeted module.
    wasm_module,

    pub fn detect() Artifact {
        if (builtin.target.isWasm()) {
            assert(builtin.output_mode == .Obj);
            assert(builtin.link_mode == .Static);
            return .wasm_module;
        }

        return switch (builtin.output_mode) {
            .Exe => .exe,
            .Lib => .lib,
            else => {
                @compileLog(builtin.output_mode);
                @compileError("unsupported artifact output mode");
            },
        };
    }
};
