/// Target for xcframework builds. This is a separate file so that
/// our runtime code doesn't need to import build code.
pub const Target = enum {
    native,
    universal,

    /// rootshell App Store builds support iOS, visionOS, and Mac Catalyst,
    /// but never consume GhosttyKit as a native macOS library.
    rootshell_appstore,

    /// rootshell Standalone is distributed only as a Mac Catalyst app.
    rootshell_standalone,
};
