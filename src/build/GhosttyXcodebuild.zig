const Ghostty = @This();

const std = @import("std");
const builtin = @import("builtin");
const RunStep = std.Build.Step.Run;
const Config = @import("Config.zig");
const XCFramework = @import("GhosttyXCFramework.zig");

xcodebuild: *std.Build.Step.Run,
open: *std.Build.Step.Run,

pub fn init(
    b: *std.Build,
    config: *const Config,
    xcframework: *const XCFramework,
) !Ghostty {
    const xc_config = switch (config.optimize) {
        .Debug => "Debug",
        .ReleaseSafe,
        .ReleaseSmall,
        .ReleaseFast,
        => "Release",
    };

    // Our step to build the Ghostty macOS app.
    const build = build: {
        // External environment variables can mess up xcodebuild, so
        // we create a new empty environment.
        const env_map = try b.allocator.create(std.process.EnvMap);
        env_map.* = .init(b.allocator);

        const build = RunStep.create(b, "xcodebuild");
        build.has_side_effects = true;
        build.cwd = b.path("macos");
        build.env_map = env_map;
        build.addArgs(&.{
            "xcodebuild",
            "-target",
            "Ghostty",
            "-configuration",
            xc_config,
        });

        switch (xcframework.target) {
            // Universal is our default target, so we don't have to
            // add anything.
            .universal => {},

            // Native we need to override the architecture in the Xcode
            // project with the -arch flag.
            .native => build.addArgs(&.{
                "-arch",
                switch (builtin.cpu.arch) {
                    .aarch64 => "arm64",
                    .x86_64 => "x86_64",
                    else => @panic("unsupported macOS arch"),
                },
            }),
        }

        // We need the xcframework
        build.step.dependOn(xcframework.xcframework.step);

        // Expect success
        build.expectExitCode(0);

        // Capture stdout/stderr so we don't pollute our zig build
        // _ = build.captureStdOut();
        // _ = build.captureStdErr();
        break :build build;
    };

    // Our step to open the resulting Ghostty app.
    const open = open: {
        const open = RunStep.create(b, "run Ghostty app");
        open.has_side_effects = true;
        open.cwd = b.path("macos");
        open.addArgs(&.{
            b.fmt(
                "build/{s}/Ghostty.app/Contents/MacOS/ghostty",
                .{xc_config},
            ),
        });

        // Open depends on the app
        open.step.dependOn(&build.step);

        // This overrides our default behavior and forces logs to show
        // up on stderr (in addition to the centralized macOS log).
        open.setEnvironmentVariable("GHOSTTY_LOG", "1");

        // This is hack so that we can activate the app and bring it to
        // the front forcibly even though we're executing directly
        // via the binary and not launch services.
        open.setEnvironmentVariable("GHOSTTY_MAC_ACTIVATE", "1");

        if (b.args) |args| {
            open.addArgs(args);
        } else {
            // This tricks the app into thinking it's running from the
            // app bundle so we don't execute our CLI mode.
            open.setEnvironmentVariable("GHOSTTY_MAC_APP", "1");
        }

        break :open open;
    };

    return .{
        .xcodebuild = build,
        .open = open,
    };
}

pub fn install(self: *const Ghostty) void {
    const b = self.xcodebuild.step.owner;
    b.getInstallStep().dependOn(&self.xcodebuild.step);
}
