/// Imported C API directly from header files
pub const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("adwaita.h");

    // generated header files
    @cInclude("ghostty_resources.h");

    // compatibility
    @cInclude("ghostty_gtk_compat.h");
});
