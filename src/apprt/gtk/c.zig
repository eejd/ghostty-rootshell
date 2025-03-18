/// Imported C API directly from header files
pub const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("adwaita.h");

    // compatibility
    @cInclude("ghostty_gtk_compat.h");
});
