const std = @import("std");
const Allocator = std.mem.Allocator;
const EnvMap = std.process.EnvMap;
const config = @import("../config.zig");

const log = std.log.scoped(.shell_integration);

/// Shell types we support
pub const Shell = enum {
    fish,
    zsh,
};

/// Setup the command execution environment for automatic
/// integrated shell integration. This returns true if shell
/// integration was successful. False could mean many things:
/// the shell type wasn't detected, etc.
///
/// The allocator is only used for temporary values, so it should
/// be given a general purpose allocator. No allocated memory remains
/// after this function returns except anything allocated by the
/// EnvMap.
pub fn setup(
    alloc: Allocator,
    resource_dir: []const u8,
    command_path: []const u8,
    env: *EnvMap,
    force_shell: ?Shell,
    features: config.ShellIntegrationFeatures,
) !?Shell {
    const exe = if (force_shell) |shell| switch (shell) {
        .fish => "fish",
        .zsh => "zsh",
    } else std.fs.path.basename(command_path);

    const shell: Shell = shell: {
        if (std.mem.eql(u8, "fish", exe)) {
            try setupFish(alloc, resource_dir, env);
            break :shell .fish;
        }

        if (std.mem.eql(u8, "zsh", exe)) {
            try setupZsh(resource_dir, env);
            break :shell .zsh;
        }

        return null;
    };

    // Setup our feature env vars
    if (!features.cursor) try env.put("GHOSTTY_SHELL_INTEGRATION_NO_CURSOR", "1");
    if (!features.sudo) try env.put("GHOSTTY_SHELL_INTEGRATION_NO_SUDO", "1");
    if (!features.title) try env.put("GHOSTTY_SHELL_INTEGRATION_NO_TITLE", "1");

    return shell;
}

/// Setup the fish automatic shell integration. This works by
/// modify XDG_DATA_DIRS to include the resource directory.
/// Fish will automatically load configuration in XDG_DATA_DIRS
/// "fish/vendor_conf.d/*.fish".
fn setupFish(
    alloc_gpa: Allocator,
    resource_dir: []const u8,
    env: *EnvMap,
) !void {
    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

    // Get our path to the shell integration directory.
    const integ_dir = try std.fmt.bufPrint(
        &path_buf,
        "{s}/shell-integration",
        .{resource_dir},
    );

    // Set an env var so we can remove this from XDG_DATA_DIRS later.
    // This happens in the shell integration config itself. We do this
    // so that our modifications don't interfere with other commands.
    try env.put("GHOSTTY_FISH_XDG_DIR", integ_dir);

    if (env.get("XDG_DATA_DIRS")) |old| {
        // We have an old value, We need to prepend our value to it.

        // We attempt to avoid allocating by using the stack up to 4K.
        // Max stack size is considerably larger on macOS and Linux but
        // 4K is a reasonable size for this for most cases. However, env
        // vars can be significantly larger so if we have to we fall
        // back to a heap allocated value.
        var stack_alloc = std.heap.stackFallback(4096, alloc_gpa);
        const alloc = stack_alloc.get();
        const prepended = try std.fmt.allocPrint(
            alloc,
            "{s}{c}{s}",
            .{ integ_dir, std.fs.path.delimiter, old },
        );
        defer alloc.free(prepended);

        try env.put("XDG_DATA_DIRS", prepended);
    } else {
        // No XDG_DATA_DIRS set, we just set it our desired value.
        try env.put("XDG_DATA_DIRS", integ_dir);
    }
}

/// Setup the zsh automatic shell integration. This works by setting
/// ZDOTDIR to our resources dir so that zsh will load our config. This
/// config then loads the true user config.
fn setupZsh(
    resource_dir: []const u8,
    env: *EnvMap,
) !void {
    // Preserve the old zdotdir value so we can recover it.
    if (env.get("ZDOTDIR")) |old| {
        try env.put("GHOSTTY_ZSH_ZDOTDIR", old);
    }

    // Set our new ZDOTDIR
    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const integ_dir = try std.fmt.bufPrint(
        &path_buf,
        "{s}/shell-integration/zsh",
        .{resource_dir},
    );
    try env.put("ZDOTDIR", integ_dir);
}

test "force shell" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = EnvMap.init(alloc);
    defer env.deinit();

    inline for (@typeInfo(Shell).Enum.fields) |field| {
        const shell = @field(Shell, field.name);
        try testing.expectEqual(shell, setup(alloc, ".", "sh", &env, shell, .{}));
    }
}
