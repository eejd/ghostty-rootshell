const std = @import("std");
const c = @import("c.zig");

pub const Result = enum(c_uint) {
    match = c.FcResultMatch,
    no_match = c.FcResultNoMatch,
    type_mismatch = c.FcResultTypeMismatch,
    no_id = c.FcResultNoId,
    out_of_memory = c.FcResultOutOfMemory,
};

pub const MatchKind = enum(c_uint) {
    pattern = c.FcMatchPattern,
    font = c.FcMatchFont,
    scan = c.FcMatchScan,
};
