const stream = @import("stream.zig");
const ansi = @import("ansi.zig");
const csi = @import("csi.zig");
const sgr = @import("sgr.zig");
pub const point = @import("point.zig");
pub const color = @import("color.zig");

pub const Terminal = @import("Terminal.zig");
pub const Parser = @import("Parser.zig");
pub const Selection = @import("Selection.zig");
pub const Screen = @import("Screen.zig");
pub const Stream = stream.Stream;
pub const CursorStyle = ansi.CursorStyle;
pub const DeviceAttributeReq = ansi.DeviceAttributeReq;
pub const DeviceStatusReq = ansi.DeviceStatusReq;
pub const Mode = ansi.Mode;
pub const StatusLineType = ansi.StatusLineType;
pub const StatusDisplay = ansi.StatusDisplay;
pub const EraseDisplay = csi.EraseDisplay;
pub const EraseLine = csi.EraseLine;
pub const TabClear = csi.TabClear;
pub const Attribute = sgr.Attribute;

// Not exported because they're just used for tests.

test {
    _ = ansi;
    _ = color;
    _ = csi;
    _ = point;
    _ = sgr;
    _ = stream;
    _ = Parser;
    _ = Selection;
    _ = Terminal;
    _ = Screen;

    _ = @import("osc.zig");
    _ = @import("parse_table.zig");
    _ = @import("Tabstops.zig");
}
