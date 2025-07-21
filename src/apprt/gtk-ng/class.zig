//! This files contains all the GObject classes for the GTK apprt
//! along with helpers to work with them.

const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

pub const Application = @import("class/application.zig").Application;
pub const Window = @import("class/window.zig").Window;
pub const Config = @import("class/config.zig").Config;
pub const Surface = @import("class/surface.zig").Surface;

/// Common methods for all GObject classes we create.
pub fn Common(
    comptime Self: type,
    comptime Private: ?type,
) type {
    return struct {
        /// Upcast our type to a parent type or interface. This will fail at
        /// compile time if the cast isn't 100% safe. For unsafe casts,
        /// use `gobject.ext.cast` instead. We don't have a helper for that
        /// because its uncommon and unsafe behavior should be noisier.
        pub fn as(self: *Self, comptime T: type) *T {
            return gobject.ext.as(T, self);
        }

        /// Increase the reference count of the object.
        pub fn ref(self: *Self) *Self {
            return @ptrCast(@alignCast(gobject.Object.ref(self.as(gobject.Object))));
        }

        /// Decrease the reference count of the object.
        pub fn unref(self: *Self) void {
            gobject.Object.unref(self.as(gobject.Object));
        }

        /// Access the private data of the object. This should be forwarded
        /// via a non-pub const usually.
        pub const private = if (Private) |P| (struct {
            fn private(self: *Self) *P {
                return gobject.ext.impl_helpers.getPrivate(
                    self,
                    P,
                    P.offset,
                );
            }
        }).private else {};

        /// A helper that can be used to create a property that reads and
        /// writes a private `?[:0]const u8` field type.
        ///
        /// Reading the property will result in a copy of the string
        /// and callers are responsible for freeing it.
        ///
        /// Writing the property will free the previous value and copy
        /// the new value into the private field.
        ///
        /// The object class (Self) must still free the private field
        /// in finalize!
        pub fn privateStringFieldAccessor(
            comptime name: []const u8,
        ) gobject.ext.Accessor(
            Self,
            @FieldType(Private.?, name),
        ) {
            const S = struct {
                fn getter(self: *Self) ?[:0]const u8 {
                    return @field(private(self), name);
                }

                fn setter(self: *Self, value: ?[:0]const u8) void {
                    const priv = private(self);
                    if (@field(priv, name)) |v| {
                        glib.free(@constCast(@ptrCast(v)));
                    }

                    // We don't need to copy this because it was already
                    // copied by the typedAccessor.
                    @field(priv, name) = value;
                }
            };

            return gobject.ext.typedAccessor(
                Self,
                ?[:0]const u8,
                .{
                    .getter = S.getter,
                    .getter_transfer = .none,
                    .setter = S.setter,
                    .setter_transfer = .full,
                },
            );
        }

        /// Common class functions.
        pub const Class = struct {
            pub fn as(class: *Self.Class, comptime T: type) *T {
                return gobject.ext.as(T, class);
            }

            /// Bind a template child to a private entry in the class.
            pub const bindTemplateChildPrivate = if (Private) |P| (struct {
                pub fn bindTemplateChildPrivate(
                    class: *Self.Class,
                    comptime name: [:0]const u8,
                    comptime options: gtk.ext.BindTemplateChildOptions,
                ) void {
                    gtk.ext.impl_helpers.bindTemplateChildPrivate(
                        class,
                        name,
                        P,
                        P.offset,
                        options,
                    );
                }
            }).bindTemplateChildPrivate else {};
        };
    };
}

test {
    @import("std").testing.refAllDecls(@This());
}
