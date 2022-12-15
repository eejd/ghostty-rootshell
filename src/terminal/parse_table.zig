//! The primary export of this file is "table", which contains a
//! comptime-generated state transition table for VT emulation.
//!
//! This is based on the vt100.net state machine:
//! https://vt100.net/emu/dec_ansi_parser
//! But has some modifications:
//!
//!   * utf8 state introduced to detect UTF8-encoded sequences. The
//!     actual handling back OUT of the utf8 state is done manualy in the
//!     parser.
//!
//!   * csi_param accepts the colon character (':') since the SGR command
//!     accepts colon as a valid parameter value.
//!

const std = @import("std");
const builtin = @import("builtin");
const parser = @import("Parser.zig");
const State = parser.State;
const Action = parser.TransitionAction;

/// The state transition table. The type is [u8][State]Transition but
/// comptime-generated to be exactly-sized.
pub const table = genTable();

/// Table is the type of the state table. This is dynamically (comptime)
/// generated to be exactly sized.
pub const Table = genTableType();

// Transition is the transition to take within the table
pub const Transition = struct {
    state: State,
    action: Action,
};

/// Table is the type of the state transition table.
fn genTableType() type {
    const max_u8 = std.math.maxInt(u8);
    const stateInfo = @typeInfo(State);
    const max_state = stateInfo.Enum.fields.len;
    return [max_u8 + 1][max_state]Transition;
}

/// Function to generate the full state transition table for VT emulation.
fn genTable() Table {
    @setEvalBranchQuota(20000);
    var result: Table = undefined;

    // Initialize everything so every state transition exists
    var i: usize = 0;
    while (i < result.len) : (i += 1) {
        var j: usize = 0;
        while (j < result[0].len) : (j += 1) {
            result[i][j] = transition(.anywhere, .none);
        }
    }

    // ground
    {
        const source = State.ground;

        // anywhere =>
        single(&result, 0x18, .anywhere, .ground, .execute);
        single(&result, 0x1A, .anywhere, .ground, .execute);
        single(&result, 0x9C, .anywhere, .ground, .none);

        // events
        single(&result, 0x19, .ground, .ground, .execute);
        range(&result, 0, 0x17, .ground, .ground, .execute);
        range(&result, 0x1C, 0x1F, .ground, .ground, .execute);
        range(&result, 0x20, 0x7F, .ground, .ground, .print);

        // => utf8
        range(&result, 0xC2, 0xDF, source, .utf8, .collect);
        range(&result, 0xE0, 0xEF, source, .utf8, .collect);
        range(&result, 0xF0, 0xF4, source, .utf8, .collect);
    }

    // escape_intermediate
    {
        const source = State.escape_intermediate;

        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        range(&result, 0x20, 0x2F, source, source, .collect);
        single(&result, 0x7F, source, source, .ignore);

        // => ground
        range(&result, 0x30, 0x7E, source, .ground, .esc_dispatch);
    }

    // sos_pm_apc_string
    {
        const source = State.sos_pm_apc_string;

        // anywhere =>
        single(&result, 0x98, .anywhere, source, .none);
        single(&result, 0x9E, .anywhere, source, .none);
        single(&result, 0x9F, .anywhere, source, .none);

        // events
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);
        range(&result, 0x20, 0x7F, source, source, .ignore);

        // => ground
        single(&result, 0x9C, source, .ground, .none);
    }

    // escape
    {
        const source = State.escape;

        // anywhere =>
        single(&result, 0x1B, .anywhere, source, .none);

        // events
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        single(&result, 0x7F, source, source, .ignore);

        // => ground
        range(&result, 0x30, 0x4F, source, .ground, .esc_dispatch);
        range(&result, 0x51, 0x57, source, .ground, .esc_dispatch);
        range(&result, 0x60, 0x7E, source, .ground, .esc_dispatch);
        single(&result, 0x59, source, .ground, .esc_dispatch);
        single(&result, 0x5A, source, .ground, .esc_dispatch);
        single(&result, 0x5C, source, .ground, .esc_dispatch);

        // => escape_intermediate
        range(&result, 0x20, 0x2F, source, .escape_intermediate, .collect);

        // => sos_pm_apc_string
        single(&result, 0x58, source, .sos_pm_apc_string, .none);
        single(&result, 0x5E, source, .sos_pm_apc_string, .none);
        single(&result, 0x5F, source, .sos_pm_apc_string, .none);

        // => dcs_entry
        single(&result, 0x50, source, .dcs_entry, .none);

        // => csi_entry
        single(&result, 0x5B, source, .csi_entry, .none);

        // => osc_string
        single(&result, 0x5D, source, .osc_string, .none);
    }

    // dcs_entry
    {
        const source = State.dcs_entry;

        // anywhere =>
        single(&result, 0x90, .anywhere, source, .ignore);

        // events
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);
        single(&result, 0x7F, source, source, .ignore);

        // => dcs_intermediate
        range(&result, 0x20, 0x2F, source, .dcs_intermediate, .collect);

        // => dcs_ignore
        single(&result, 0x3A, source, .dcs_ignore, .none);

        // => dcs_param
        range(&result, 0x30, 0x39, source, .dcs_param, .param);
        single(&result, 0x3B, source, .dcs_param, .param);
        range(&result, 0x3C, 0x3F, source, .dcs_param, .collect);

        // => dcs_passthrough
        range(&result, 0x40, 0x7E, source, .dcs_passthrough, .none);
    }

    // dcs_intermediate
    {
        const source = State.dcs_intermediate;

        // events
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);
        range(&result, 0x20, 0x2F, source, source, .collect);
        single(&result, 0x7F, source, source, .ignore);

        // => dcs_ignore
        range(&result, 0x30, 0x3F, source, .dcs_ignore, .none);

        // => dcs_passthrough
        range(&result, 0x40, 0x7E, source, .dcs_passthrough, .none);
    }

    // dcs_ignore
    {
        const source = State.dcs_ignore;

        // events
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);

        // => ground
        single(&result, 0x9C, source, .ground, .none);
    }

    // dcs_param
    {
        const source = State.dcs_param;

        // events
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);
        range(&result, 0x30, 0x39, source, source, .param);
        single(&result, 0x3B, source, source, .param);
        single(&result, 0x7F, source, source, .ignore);

        // => dcs_ignore
        single(&result, 0x3A, source, .dcs_ignore, .none);
        range(&result, 0x3C, 0x3F, source, .dcs_ignore, .none);

        // => dcs_intermediate
        range(&result, 0x20, 0x2F, source, .dcs_intermediate, .collect);

        // => dcs_passthrough
        range(&result, 0x40, 0x7E, source, .dcs_passthrough, .none);
    }

    // dcs_passthrough
    {
        const source = State.dcs_passthrough;

        // events
        single(&result, 0x19, source, source, .put);
        range(&result, 0, 0x17, source, source, .put);
        range(&result, 0x1C, 0x1F, source, source, .put);
        range(&result, 0x20, 0x7E, source, source, .put);
        single(&result, 0x7F, source, source, .ignore);

        // => ground
        single(&result, 0x9C, source, .ground, .none);
    }

    // csi_param
    {
        const source = State.csi_param;

        // events
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        range(&result, 0x30, 0x39, source, source, .param);
        single(&result, 0x3A, source, source, .param);
        single(&result, 0x3B, source, source, .param);
        single(&result, 0x7F, source, source, .ignore);

        // => ground
        range(&result, 0x40, 0x7E, source, .ground, .csi_dispatch);

        // => csi_ignore
        range(&result, 0x3C, 0x3F, source, .csi_ignore, .none);

        // => csi_intermediate
        range(&result, 0x20, 0x2F, source, .csi_intermediate, .collect);
    }

    // csi_ignore
    {
        const source = State.csi_ignore;

        // events
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        range(&result, 0x20, 0x3F, source, source, .ignore);
        single(&result, 0x7F, source, source, .ignore);

        // => ground
        range(&result, 0x40, 0x7E, source, .ground, .none);
    }

    // csi_intermediate
    {
        const source = State.csi_intermediate;

        // events
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        range(&result, 0x20, 0x2F, source, source, .collect);
        single(&result, 0x7F, source, source, .ignore);

        // => ground
        range(&result, 0x40, 0x7E, source, .ground, .csi_dispatch);

        // => csi_ignore
        range(&result, 0x30, 0x3F, source, .csi_ignore, .none);
    }

    // csi_entry
    {
        const source = State.csi_entry;

        // anywhere =>
        single(&result, 0x9B, .anywhere, source, .none);

        // events
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        single(&result, 0x7F, source, source, .ignore);

        // => ground
        range(&result, 0x40, 0x7E, source, .ground, .csi_dispatch);

        // => csi_ignore
        single(&result, 0x3A, source, .csi_ignore, .none);

        // => csi_intermediate
        range(&result, 0x20, 0x2F, source, .csi_intermediate, .collect);

        // => csi_param
        range(&result, 0x30, 0x39, source, .csi_param, .param);
        single(&result, 0x3B, source, .csi_param, .param);
        range(&result, 0x3C, 0x3F, source, .csi_param, .collect);
    }

    // osc_string
    {
        const source = State.osc_string;

        // anywhere =>
        single(&result, 0x9D, .anywhere, source, .none);

        // events
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x06, source, source, .ignore);
        range(&result, 0x08, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);
        range(&result, 0x20, 0x7F, source, source, .osc_put);

        // => ground
        single(&result, 0x07, source, .ground, .none);
        single(&result, 0x9C, source, .ground, .none);
    }

    return result;
}

fn single(t: *Table, c: u8, s0: State, s1: State, a: Action) void {
    // In debug mode, we want to verify that every state is marked
    // exactly once.
    if (builtin.mode == .Debug) {
        const existing = t[c][@enumToInt(s0)];
        if (existing.state != .anywhere) {
            std.debug.print("transition set multiple times c={} s0={} existing={}", .{
                c, s0, existing,
            });
            unreachable;
        }
    }

    t[c][@enumToInt(s0)] = transition(s1, a);
}

fn range(t: *Table, from: u8, to: u8, s0: State, s1: State, a: Action) void {
    var i = from;
    while (i <= to) : (i += 1) single(t, i, s0, s1, a);
}

fn transition(state: State, action: Action) Transition {
    return .{ .state = state, .action = action };
}

test {
    // This forces comptime-evaluation of table, so we're just testing
    // that it succeeds in creation.
    _ = table;
}
