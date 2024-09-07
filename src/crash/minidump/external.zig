//! This file contains the external structs and constants for the minidump
//! format. Most are from the Microsoft documentation on the minidump format:
//! https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/
//!
//! Wherever possible, we also compare our definitions to other projects
//! such as rust-minidump, libmdmp, breakpad, etc. to ensure we're doing
//! the right thing.

/// "MDMP" in little-endian.
pub const signature = 0x504D444D;

/// The version of the minidump format.
pub const version = 0xA793;

/// https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/ns-minidumpapiset-minidump_header
pub const Header = extern struct {
    signature: u32,
    version: packed struct(u32) { low: u16, high: u16 },
    stream_count: u32,
    stream_directory_rva: u32,
    checksum: u32,
    time_date_stamp: u32,
    flags: u64,
};

/// https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/ns-minidumpapiset-minidump_directory
pub const Directory = extern struct {
    stream_type: u32,
    location: LocationDescriptor,
};

/// https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/ns-minidumpapiset-minidump_location_descriptor
pub const LocationDescriptor = extern struct {
    data_size: u32,
    rva: u32,
};
