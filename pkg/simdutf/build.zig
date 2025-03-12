const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = target: {
        var query = b.standardTargetOptionsQueryOnly(.{});

        // This works around a Zig 0.14 bug where targeting an iOS
        // simulator sets our CPU model to be "apple_a7" which is
        // too outdated to support SIMD features and is also wrong.
        // Simulator binaries run on the host CPU so target native.
        //
        // We can remove this when the following builds without
        // issue without this line:
        //
        //   zig build -Dtarget=aarch64-ios.17.0-simulator
        //
        if (query.abi) |abi| {
            if (abi == .simulator) {
                query.cpu_model = .native;
            }
        }

        break :target b.resolveTargetQuery(query);
    };

    const lib = b.addStaticLibrary(.{
        .name = "simdutf",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibCpp();
    lib.addIncludePath(b.path("vendor"));

    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib.root_module);
    }

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    // Zig 0.13 bug: https://github.com/ziglang/zig/issues/20414
    // (See root Ghostty build.zig on why we do this)
    try flags.appendSlice(&.{"-DSIMDUTF_IMPLEMENTATION_ICELAKE=0"});

    lib.addCSourceFiles(.{
        .flags = flags.items,
        .files = &.{
            "vendor/simdutf.cpp",
        },
    });
    lib.installHeadersDirectory(
        b.path("vendor"),
        "",
        .{ .include_extensions = &.{".h"} },
    );

    b.installArtifact(lib);

    // {
    //     const test_exe = b.addTest(.{
    //         .name = "test",
    //         .root_source_file = .{ .path = "main.zig" },
    //         .target = target,
    //         .optimize = optimize,
    //     });
    //     test_exe.linkLibrary(lib);
    //
    //     var it = module.import_table.iterator();
    //     while (it.next()) |entry| test_exe.root_module.addImport(entry.key_ptr.*, entry.value_ptr.*);
    //     const tests_run = b.addRunArtifact(test_exe);
    //     const test_step = b.step("test", "Run tests");
    //     test_step.dependOn(&tests_run.step);
    // }
}
