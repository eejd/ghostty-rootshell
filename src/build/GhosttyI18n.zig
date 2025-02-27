const GhosttyI18n = @This();

const std = @import("std");
const Config = @import("Config.zig");
const gresource = @import("../apprt/gtk/gresource.zig");

const domain = "com.mitchellh.ghostty";

const locales = [_][]const u8{
    "zh_CN.UTF-8",
};

owner: *std.Build,
steps: []*std.Build.Step,

pub fn init(b: *std.Build, cfg: *const Config) !GhosttyI18n {
    var steps = std.ArrayList(*std.Build.Step).init(b.allocator);
    errdefer steps.deinit();

    try addUpdateStep(b);

    if (cfg.app_runtime == .gtk) {
        // Output the .mo files used by the GTK apprt
        inline for (locales) |locale| {
            const msgfmt = b.addSystemCommand(&.{ "msgfmt", "-o", "-" });

            msgfmt.addFileArg(b.path("po/" ++ locale ++ ".po"));

            try steps.append(&b.addInstallFile(
                msgfmt.captureStdOut(),
                std.fmt.comptimePrint("share/locale/{s}/LC_MESSAGES/{s}.mo", .{ locale, domain }),
            ).step);
        }
    }

    return .{
        .owner = b,
        .steps = try steps.toOwnedSlice(),
    };
}

pub fn install(self: *const GhosttyI18n) void {
    for (self.steps) |step| self.owner.getInstallStep().dependOn(step);
}

fn addUpdateStep(b: *std.Build) !void {
    const pot_step = b.step("update-translations", "Update translation files");

    const xgettext = b.addSystemCommand(&.{
        "xgettext",
        "--language=C", // Silence the "unknown extension" errors
        "--from-code=UTF-8",
        "--add-comments=Translators",
        "--keyword=_",
        "--keyword=C_:1c,2",
        "--package-name=" ++ domain,
        "--msgid-bugs-address=m@mitchellh.com",
        "--copyright-holder=Mitchell Hashimoto",
        "-o",
        "-",
    });

    inline for (gresource.blueprint_files) |blp| {
        // We avoid using addFileArg here since the full, absolute file path
        // would be added to the file as its location, which differs for
        // everyone's checkout of the repository.
        // This comes at a cost of losing per-file caching, of course.
        xgettext.addArg(std.fmt.comptimePrint("src/apprt/gtk/ui/{[major]}.{[minor]}/{[name]s}.blp", blp));
    }

    var gtk_files = try b.build_root.handle.openDir("src/apprt/gtk", .{ .iterate = true });
    defer gtk_files.close();

    var walk = try gtk_files.walk(b.allocator);
    defer walk.deinit();

    while (try walk.next()) |src| {
        switch (src.kind) {
            .file => if (!std.mem.endsWith(u8, src.basename, ".zig")) continue,
            else => continue,
        }
        xgettext.addArg((b.pathJoin(&.{ "src/apprt/gtk", src.path })));
    }

    // Don't make Zig cache it
    xgettext.has_side_effects = true;

    const new_pot = xgettext.captureStdOut();

    const wf = b.addWriteFiles();
    wf.addCopyFileToSource(new_pot, "po/" ++ domain ++ ".pot");

    inline for (locales) |locale| {
        const msgmerge = b.addSystemCommand(&.{ "msgmerge", "-q" });
        msgmerge.addFileArg(b.path("po/" ++ locale ++ ".po"));
        msgmerge.addFileArg(xgettext.captureStdOut());

        wf.addCopyFileToSource(msgmerge.captureStdOut(), "po/" ++ locale ++ ".po");
    }

    pot_step.dependOn(&wf.step);
}
