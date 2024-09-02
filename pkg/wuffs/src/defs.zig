//! Define all of the C macros that WUFFS uses to configure itself here so
//! that the settings used to import the C "header" file stay in sync with the
//! settings used build the C "source" file.

pub const cimport = [_][]const u8{
    "WUFFS_CONFIG__MODULES",
    "WUFFS_CONFIG__MODULE__AUX__BASE",
    "WUFFS_CONFIG__MODULE__AUX__IMAGE",
    "WUFFS_CONFIG__MODULE__BASE",
    "WUFFS_CONFIG__MODULE__ADLER32",
    "WUFFS_CONFIG__MODULE__CRC32",
    "WUFFS_CONFIG__MODULE__DEFLATE",
    "WUFFS_CONFIG__MODULE__JPEG",
    "WUFFS_CONFIG__MODULE__PNG",
    "WUFFS_CONFIG__MODULE__ZLIB",
};

// The only difference should be that the "build" defines WUFFS_IMPLEMENTATION
pub const build = [_][]const u8{
    "WUFFS_IMPLEMENTATION",
} ++ cimport;
