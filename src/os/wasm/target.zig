/// The wasm target platform. This is used to toggle certain features
/// on and off since the standard triple target is often not specific
/// enough (i.e. we can't tell wasm32-freestanding is for browser or not).
pub const Target = enum {
    browser,
};
