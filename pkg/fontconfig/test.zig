const std = @import("std");
const fontconfig = @import("main.zig");

test "fc-list" {
    const testing = std.testing;

    var cfg = fontconfig.initLoadConfigAndFonts();
    defer cfg.destroy();

    var pat = fontconfig.Pattern.create();
    defer pat.destroy();

    var os = fontconfig.ObjectSet.create();
    defer os.destroy();

    var fs = cfg.list(pat, os);
    defer fs.destroy();

    // Note: this is environmental, but in general we expect all our
    // testing environments to have at least one font.
    try testing.expect(fs.len() > 0);
}
