//! A Zig build step that generates Vim plugin files for Ghostty's configuration
//! file.

const VimStep = @This();

const std = @import("std");
const Step = std.Build.Step;

const Config = @import("../config/Config.zig");

step: *Step,

// The build step that generates the file contents
generate_step: Step,

pub fn create(b: *std.Build) *VimStep {
    const self = b.allocator.create(VimStep) catch @panic("OOM");

    const write_file = Step.WriteFile.create(b);

    self.* = .{
        .step = &write_file.step,
        .generate_step = Step.init(.{
            .id = .custom,
            .name = "generate Vim plugin files",
            .owner = b,
            .makeFn = make,
        }),
    };

    write_file.step.dependOn(&self.generate_step);

    return self;
}

pub fn getDirectory(self: *VimStep) std.Build.LazyPath {
    const wf = @fieldParentPtr(Step.WriteFile, "step", self.step);
    return wf.getDirectory();
}

fn make(step: *Step, prog_node: *std.Progress.Node) !void {
    _ = prog_node;
    const self = @fieldParentPtr(VimStep, "generate_step", step);
    const wf = @fieldParentPtr(Step.WriteFile, "step", self.step);
    const b = step.owner;

    // syntax/ghostty.vim
    {
        var buf = std.ArrayList(u8).init(b.allocator);
        defer buf.deinit();

        const writer = buf.writer();
        try writer.print(
            \\" Vim syntax file
            \\" Language: Ghostty config file
            \\" Maintainer: Ghostty <https://github.com/mitchellh/ghostty>
            \\"
            \\" THIS FILE IS AUTO-GENERATED
            \\
            \\if exists('b:current_syntax')
            \\  finish
            \\endif
            \\
            \\let b:current_syntax = 'ghostty'
            \\
            \\let s:cpo_save = &cpo
            \\set cpo&vim
            \\
            \\
        , .{});

        const config_fields = @typeInfo(Config).Struct.fields;
        var keywords = try std.ArrayList([]const u8).initCapacity(
            b.allocator,
            config_fields.len,
        );
        defer keywords.deinit();

        inline for (config_fields) |field| {
            // Ignore fields which begin with _
            if (field.name[0] != '_') {
                keywords.appendAssumeCapacity(field.name);
            }
        }

        try writer.print(
            \\syn keyword ghosttyConfigKeyword
            \\	\ {s}
            \\
            \\syn match ghosttyConfigComment /#.*/ contains=@Spell
            \\
            \\hi def link ghosttyConfigComment Comment
            \\hi def link ghosttyConfigKeyword Keyword
            \\
            \\let &cpo = s:cpo_save
            \\unlet s:cpo_save
            \\
        , .{
            try std.mem.join(b.allocator, "\n\t\\ ", keywords.items),
        });

        _ = wf.add("syntax/ghostty.vim", buf.items);
    }

    // ftdetect/ghostty.vim
    {
        _ = wf.add(
            "ftdetect/ghostty.vim",
            "au BufRead,BufNewFile */.config/ghostty/config set ft=ghostty\n",
        );
    }

    // ftplugin/ghostty.vim
    {
        var buf = std.ArrayList(u8).init(b.allocator);
        defer buf.deinit();

        const writer = buf.writer();
        try writer.writeAll(
            \\" Vim filetype plugin file
            \\" Language: Ghostty config file
            \\" Maintainer: Ghostty <https://github.com/mitchellh/ghostty>
            \\"
            \\" THIS FILE IS AUTO-GENERATED
            \\
            \\if exists('b:did_ftplugin')
            \\  finish
            \\endif
            \\let b:did_ftplugin = 1
            \\
            \\setlocal commentstring=#%s
            \\setlocal iskeyword+=-
            \\
            \\" Use syntax keywords for completion
            \\setlocal omnifunc=syntaxcomplete#Complete
            \\
            \\let b:undo_ftplugin = 'setl cms< isk< ofu<'
            \\
        );

        _ = wf.add("ftplugin/ghostty.vim", buf.items);
    }
}
