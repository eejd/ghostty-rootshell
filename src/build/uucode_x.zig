const get = @import("get.zig");
const tableFor = get.tableFor;
const data = get.data;

pub fn width(cp: u21) u2 {
    const table = comptime tableFor("width");
    return data(table, cp).width;
}
