const std = @import("std");
const assert = std.debug.assert;
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../../apprt.zig");
const gresource = @import("../build/gresource.zig");
const i18n = @import("../../../os/main.zig").i18n;
const Common = @import("../class.zig").Common;
const Dialog = @import("dialog.zig").Dialog;

const log = std.log.scoped(.gtk_ghostty_clipboard_confirmation);

pub const ClipboardConfirmationDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = Dialog;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyClipboardConfirmationDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const @"can-remember" = struct {
            pub const name = "can-remember";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .nick = "Can Remember",
                    .blurb = "Allow remembering the choice.",
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "can_remember",
                    ),
                },
            );
        };

        pub const request = struct {
            pub const name = "request";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*apprt.ClipboardRequest,
                .{
                    .nick = "Request",
                    .blurb = "The clipboard request.",
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "request",
                    ),
                },
            );
        };

        pub const @"clipboard-contents" = struct {
            pub const name = "clipboard-contents";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*gtk.TextBuffer,
                .{
                    .nick = "Clipboard Contents",
                    .blurb = "The clipboard contents being read/written.",
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "clipboard_contents",
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// The request that this dialog is for.
        request: ?*apprt.ClipboardRequest = null,

        /// The clipboard contents being read/written.
        clipboard_contents: ?*gtk.TextBuffer = null,

        /// Whether the user can remember the choice.
        can_remember: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    fn init(self: *Self, _: *Class) callconv(.C) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Some property signals
        _ = gobject.Object.signals.notify.connect(
            self,
            ?*anyopaque,
            &propRequest,
            null,
            .{ .detail = "request" },
        );

        // Trigger initial values
        self.propRequest(undefined, null);
    }

    pub fn present(self: *Self, parent: ?*gtk.Widget) void {
        self.as(Dialog).present(parent);
    }

    //---------------------------------------------------------------
    // Signal Handlers

    fn propRequest(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        const req = priv.request orelse return;
        switch (req.*) {
            .osc_52_write => {
                self.as(Dialog.Parent).setHeading(i18n._("Authorize Clipboard Access"));
                self.as(Dialog.Parent).setBody(i18n._("An application is attempting to write to the clipboard. The current clipboard contents are shown below."));
            },
            .osc_52_read => {
                self.as(Dialog.Parent).setHeading(i18n._("Authorize Clipboard Access"));
                self.as(Dialog.Parent).setBody(i18n._("An application is attempting to read from the clipboard. The current clipboard contents are shown below."));
            },
            .paste => {
                self.as(Dialog.Parent).setHeading(i18n._("Warning: Potentially Unsafe Paste"));
                self.as(Dialog.Parent).setBody(i18n._("Pasting this text into the terminal may be dangerous as it looks like some commands may be executed."));
            },
        }
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.C) void {
        const priv = self.private();
        if (priv.clipboard_contents) |v| {
            v.unref();
            priv.clipboard_contents = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.C) void {
        const priv = self.private();
        if (priv.request) |v| {
            glib.ext.destroy(v);
            priv.request = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.C) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 2,
                    .name = "clipboard-confirmation-dialog",
                }),
            );

            // Bindings
            //class.bindTemplateChildPrivate("remember_bin", .{});

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"can-remember".impl,
                properties.@"clipboard-contents".impl,
                properties.request.impl,
            });

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
