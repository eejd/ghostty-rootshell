const Ghostty = @This();

const std = @import("std");
const builtin = @import("builtin");
const RunStep = std.Build.Step.Run;
const Config = @import("Config.zig");
const XCFramework = @import("GhosttyXCFramework.zig");

build: *std.Build.Step.Run,
open: *std.Build.Step.Run,
copy: *std.Build.Step.Run,

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

    const app_path = b.fmt("macos/build/{s}/Ghostty.app", .{xc_config});

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

        break :build build;
    };

    // Our step to open the resulting Ghostty app.
    const open = open: {
        const open = RunStep.create(b, "run Ghostty app");
        open.has_side_effects = true;
        open.cwd = b.path("");
        open.addArgs(&.{b.fmt(
            "{s}/Contents/MacOS/ghostty",
            .{app_path},
        )});

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

    // Our step to copy the app bundle to the install path.
    // We have to use `cp -R` because there are symlinks in the
    // bundle.
    const copy = copy: {
        const step = RunStep.create(b, "copy app bundle");
        step.addArgs(&.{ "cp", "-R" });
        step.addFileArg(b.path(app_path));
        step.addArg(b.fmt("{s}", .{b.install_path}));
        step.step.dependOn(&build.step);
        break :copy step;
    };

    return .{
        .build = build,
        .open = open,
        .copy = copy,
    };
}

pub fn install(self: *const Ghostty) void {
    const b = self.copy.step.owner;
    b.getInstallStep().dependOn(&self.copy.step);
}

pub fn installXcframework(self: *const Ghostty) void {
    const b = self.build.step.owner;
    b.getInstallStep().dependOn(&self.build.step);
}
