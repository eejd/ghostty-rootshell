const std = @import("std");
const Allocator = std.mem.Allocator;
const EnvMap = std.process.EnvMap;
const config = @import("../config.zig");

const log = std.log.scoped(.shell_integration);

/// Shell types we support
pub const Shell = enum {
    bash,
    fish,
    zsh,
};

pub const ShellIntegration = struct {
    /// The successfully-integrated shell.
    shell: Shell,

    /// A revised shell command. This value will be allocated
    /// with the setup() function's allocator and becomes the
    /// caller's responsibility to free it.
    command: ?[]const u8 = null,

    pub fn deinit(self: ShellIntegration, alloc: Allocator) void {
        if (self.command) |command| {
            alloc.free(command);
        }
    }
};

/// Setup the command execution environment for automatic
/// integrated shell integration and return a ShellIntegration
/// struct describing the integration.  If integration fails
/// (shell type couldn't be detected, etc.), this will return null.
///
/// The allocator is used for temporary values and to allocate values
/// in the ShellIntegration result.
pub fn setup(
    alloc: Allocator,
    resource_dir: []const u8,
    command: []const u8,
    env: *EnvMap,
    force_shell: ?Shell,
    features: config.ShellIntegrationFeatures,
) !?ShellIntegration {
    const exe = if (force_shell) |shell| switch (shell) {
        .bash => "bash",
        .fish => "fish",
        .zsh => "zsh",
    } else exe: {
        // The command can include arguments. Look for the first space
        // and use the basename of the first part as the command's exe.
        const idx = std.mem.indexOfScalar(u8, command, ' ') orelse command.len;
        break :exe std.fs.path.basename(command[0..idx]);
    };

    var new_command: ?[]const u8 = null;
    const shell: Shell = shell: {
        if (std.mem.eql(u8, "bash", exe)) {
            new_command = try setupBash(alloc, command, resource_dir, env);
            if (new_command == null) return null;
            break :shell .bash;
        }

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

    return .{
        .shell = shell,
        .command = new_command,
    };
}

test "force shell" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = EnvMap.init(alloc);
    defer env.deinit();

    inline for (@typeInfo(Shell).Enum.fields) |field| {
        const shell = @field(Shell, field.name);
        const result = try setup(alloc, ".", "sh", &env, shell, .{});

        try testing.expect(result != null);
        if (result) |r| {
            try testing.expectEqual(shell, r.shell);
            r.deinit(alloc);
        }
    }
}

/// Setup the bash automatic shell integration. This works by
/// starting bash in POSIX mode and using the ENV environment
/// variable to load our bash integration script. This prevents
/// bash from loading its normal startup files, which becomes
/// our script's responsibility (along with disabling POSIX
/// mode).
///
/// This returns a new (allocated) shell command string that
/// enables the integration or null if integration failed.
fn setupBash(
    alloc: Allocator,
    command: []const u8,
    resource_dir: []const u8,
    env: *EnvMap,
) !?[]const u8 {
    // Accumulates the arguments that will form the final shell command line.
    // We can build this list on the stack because we're just temporarily
    // referencing other slices, but we can fall back to heap in extreme cases.
    var args_alloc = std.heap.stackFallback(1024, alloc);
    var args = try std.ArrayList([]const u8).initCapacity(args_alloc.get(), 2);
    defer args.deinit();

    // Iterator that yields each argument in the original command line.
    // This will allocate once proportionate to the command line length.
    var iter = try std.process.ArgIteratorGeneral(.{}).init(alloc, command);
    defer iter.deinit();

    // Start accumulating arguments with the executable and `--posix` mode flag.
    if (iter.next()) |exe| {
        try args.append(exe);
    } else return null;
    try args.append("--posix");

    // Stores the list of intercepted command line flags that will be passed
    // to our shell integration script: --posix --norc --noprofile
    // We always include at least "1" so the script can differentiate between
    // being manually sourced or automatically injected (from here).
    var inject = try std.BoundedArray(u8, 32).init(0);
    try inject.appendSlice("1");

    var posix = false;

    // Some additional cases we don't yet cover:
    //
    //  - If the `c` shell option is set, interactive mode is disabled, so skip
    //    loading our shell integration.
    //  - If additional file arguments are provided (after a `-` or `--` flag),
    //    and the `i` shell option isn't being explicitly set, we can assume a
    //    non-interactive shell session and skip loading our shell integration.
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--posix")) {
            try inject.appendSlice(" --posix");
            posix = true;
        } else if (std.mem.eql(u8, arg, "--norc")) {
            try inject.appendSlice(" --norc");
        } else if (std.mem.eql(u8, arg, "--noprofile")) {
            try inject.appendSlice(" --noprofile");
        } else if (std.mem.eql(u8, arg, "--rcfile") or std.mem.eql(u8, arg, "--init-file")) {
            if (iter.next()) |rcfile| {
                try env.put("GHOSTTY_BASH_RCFILE", rcfile);
            }
        } else {
            try args.append(arg);
        }
    }
    try env.put("GHOSTTY_BASH_INJECT", inject.slice());

    // In POSIX mode, HISTFILE defaults to ~/.sh_history.
    if (!posix and env.get("HISTFILE") == null) {
        try env.put("HISTFILE", "~/.bash_history");
        try env.put("GHOSTTY_BASH_UNEXPORT_HISTFILE", "1");
    }

    // Preserve the existing ENV value in POSIX mode.
    if (env.get("ENV")) |old| {
        if (posix) {
            try env.put("GHOSTTY_BASH_ENV", old);
        }
    }

    // Set our new ENV to point to our integration script.
    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const integ_dir = try std.fmt.bufPrint(
        &path_buf,
        "{s}/shell-integration/bash/ghostty.bash",
        .{resource_dir},
    );
    try env.put("ENV", integ_dir);

    // Join the acculumated arguments to form the final command string.
    return try std.mem.join(alloc, " ", args.items);
}

test "bash" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const command = try setupBash(alloc, "bash", ".", &env);
    defer if (command) |c| alloc.free(c);

    try testing.expectEqualStrings("bash --posix", command.?);
    try testing.expectEqualStrings("./shell-integration/bash/ghostty.bash", env.get("ENV").?);
    try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_INJECT").?);
}

test "bash: inject flags" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // bash --posix
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, "bash --posix", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expectEqualStrings("bash --posix", command.?);
        try testing.expectEqualStrings("1 --posix", env.get("GHOSTTY_BASH_INJECT").?);
    }

    // bash --norc
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, "bash --norc", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expectEqualStrings("bash --posix", command.?);
        try testing.expectEqualStrings("1 --norc", env.get("GHOSTTY_BASH_INJECT").?);
    }

    // bash --noprofile
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, "bash --noprofile", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expectEqualStrings("bash --posix", command.?);
        try testing.expectEqualStrings("1 --noprofile", env.get("GHOSTTY_BASH_INJECT").?);
    }
}

test "bash: rcfile" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = EnvMap.init(alloc);
    defer env.deinit();

    // bash --rcfile
    {
        const command = try setupBash(alloc, "bash --rcfile profile.sh", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expectEqualStrings("bash --posix", command.?);
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }

    // bash --init-file
    {
        const command = try setupBash(alloc, "bash --init-file profile.sh", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expectEqualStrings("bash --posix", command.?);
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }
}

test "bash: HISTFILE" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // HISTFILE unset
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, "bash", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expectEqualStrings("~/.bash_history", env.get("HISTFILE").?);
        try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE").?);
    }

    // HISTFILE set
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try env.put("HISTFILE", "my_history");

        const command = try setupBash(alloc, "bash", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expectEqualStrings("my_history", env.get("HISTFILE").?);
        try testing.expect(env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE") == null);
    }

    // HISTFILE unset (POSIX mode)
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, "bash --posix", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expect(env.get("HISTFILE") == null);
        try testing.expect(env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE") == null);
    }

    // HISTFILE set (POSIX mode)
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try env.put("HISTFILE", "my_history");

        const command = try setupBash(alloc, "bash --posix", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expectEqualStrings("my_history", env.get("HISTFILE").?);
        try testing.expect(env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE") == null);
    }
}

test "bash: preserve ENV" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const original_env = "original-env.bash";

    // POSIX mode
    {
        try env.put("ENV", original_env);
        const command = try setupBash(alloc, "bash --posix", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expect(std.mem.indexOf(u8, command.?, "--posix") != null);
        try testing.expect(std.mem.indexOf(u8, env.get("GHOSTTY_BASH_INJECT").?, "posix") != null);
        try testing.expectEqualStrings(original_env, env.get("GHOSTTY_BASH_ENV").?);
        try testing.expectEqualStrings("./shell-integration/bash/ghostty.bash", env.get("ENV").?);
    }

    env.remove("GHOSTTY_BASH_ENV");

    // Not POSIX mode
    {
        try env.put("ENV", original_env);
        const command = try setupBash(alloc, "bash", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expect(std.mem.indexOf(u8, command.?, "--posix") != null);
        try testing.expect(std.mem.indexOf(u8, env.get("GHOSTTY_BASH_INJECT").?, "posix") == null);
        try testing.expect(env.get("GHOSTTY_BASH_ENV") == null);
        try testing.expectEqualStrings("./shell-integration/bash/ghostty.bash", env.get("ENV").?);
    }
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
