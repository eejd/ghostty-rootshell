//! Kitty graphics protocol support.
//!
//! Documentation:
//! https://sw.kovidgoyal.net/kitty/graphics-protocol

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Command parser parses the Kitty graphics protocol escape sequence.
pub const CommandParser = struct {
    alloc: Allocator,
    kv: std.StringHashMapUnmanaged([2]usize) = .{},
    data: std.ArrayListUnmanaged(u8) = .{},
    data_i: usize = 0,
    value_ptr: *[2]usize = undefined,
    state: State = .control_key,

    const State = enum {
        control_key,
        control_value,
        data,
    };

    pub fn deinit(self: *CommandParser) void {
        self.kv.deinit(self.alloc);
        self.data.deinit(self.alloc);
    }

    /// Feed a single byte to the parser.
    ///
    /// The first byte to start parsing should be the byte immediately following
    /// the "G" in the APC sequence, i.e. "\x1b_G123" the first byte should
    /// be "1".
    pub fn feed(self: *CommandParser, c: u8) !void {
        switch (self.state) {
            .control_key => switch (c) {
                // '=' means the key is complete and we're moving to the value.
                '=' => {
                    const key = self.data.items[self.data_i..];
                    const gop = try self.kv.getOrPut(self.alloc, key);
                    self.state = .control_value;
                    self.value_ptr = gop.value_ptr;
                    self.data_i = self.data.items.len;
                },

                else => try self.data.append(self.alloc, c),
            },

            .control_value => switch (c) {
                // ',' means we're moving to another kv
                ',' => {
                    self.finishValue();
                    self.state = .control_key;
                },

                // ';' means we're moving to the data
                ';' => {
                    self.finishValue();
                    self.state = .data;
                },

                else => try self.data.append(self.alloc, c),
            },

            .data => try self.data.append(self.alloc, c),
        }

        // We always add to our data list because this is our stable
        // array of bytes that we'll reference everywhere else.
    }

    /// Complete the parsing. This must be called after all the
    /// bytes have been fed to the parser.
    pub fn complete(self: *CommandParser) !void {
        switch (self.state) {
            // We can't ever end in the control key state and be valid.
            // This means the command looked something like "a=1,b"
            .control_key => return error.InvalidFormat,

            // Some commands (i.e. placements) end without extra data so
            // we end in the value state. i.e. "a=1,b=2"
            .control_value => self.finishValue(),

            // Most commands end in data, i.e. "a=1,b=2;1234"
            .data => {},
        }
    }

    fn finishValue(self: *CommandParser) void {
        self.value_ptr.* = .{ self.data_i, self.data.items.len };
        self.data_i = self.data.items.len;
    }
};

test "parse" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p: CommandParser = .{ .alloc = alloc };
    defer p.deinit();

    const input = "f=24,s=10,v=20";
    for (input) |c| try p.feed(c);
    try p.complete();

    try testing.expectEqual(@as(u32, 3), p.kv.count());
}

pub const Command = struct {
    control: Control,
    quiet: Quiet = .no,

    pub const Action = enum {
        query, // q
        transmit, // t
        transmit_and_display, // T
        display, // p
        delete, // d
        transmit_animation_frame, // f
        control_animation, // a
        compose_animation, // c
    };

    pub const Quiet = enum {
        no, // 0
        ok, // 1
        failures, // 2
    };

    pub const Control = union(Action) {
        query: Transmission,
        transmit: Transmission,
        transmit_and_display: struct {
            transmission: Transmission,
            display: Display,
        },
        display: Display,
        delete: Delete,
        transmit_animation_frame: AnimationFrameLoading,
        control_animation: AnimationControl,
        compose_animation: AnimationFrameComposition,
    };
};

pub const Transmission = struct {
    format: Format = .rgb, // f
    medium: Medium = .direct, // t
    width: u32 = 0, // s
    height: u32 = 0, // v
    size: u32 = 0, // S
    offset: u32 = 0, // O
    image_id: u32 = 0, // i
    image_number: u32 = 0, // I
    placement_id: u32 = 0, // p
    compression: Compression = .none, // o
    more_chunks: bool = false, // m

    pub const Format = enum {
        rgb, // 24
        rgba, // 32
        png, // 100
    };

    pub const Medium = enum {
        direct, // d
        file, // f
        temporary_file, // t
        shared_memory, // s
    };

    pub const Compression = enum {
        none,
        zlib_deflate, // z
    };
};

pub const Display = struct {
    x: u32 = 0, // x
    y: u32 = 0, // y
    width: u32 = 0, // w
    height: u32 = 0, // h
    x_offset: u32 = 0, // X
    y_offset: u32 = 0, // Y
    columns: u32 = 0, // c
    rows: u32 = 0, // r
    cursor_movement: CursorMovement = .after, // C
    virtual_placement: bool = false, // U
    z: u32 = 0, // z

    pub const CursorMovement = enum {
        after, // 0
        none, // 1
    };
};

pub const AnimationFrameLoading = struct {
    x: u32 = 0, // x
    y: u32 = 0, // y
    create_frame: u32 = 0, // c
    edit_frame: u32 = 0, // r
    gap_ms: u32 = 0, // z
    composition_mode: CompositionMode = .alpha_blend, // X
    background: Background = .{}, // Y

    pub const Background = packed struct(u32) {
        r: u8 = 0,
        g: u8 = 0,
        b: u8 = 0,
        a: u8 = 0,
    };
};

pub const AnimationFrameComposition = struct {
    frame: u32 = 0, // c
    edit_frame: u32 = 0, // r
    x: u32 = 0, // x
    y: u32 = 0, // y
    width: u32 = 0, // w
    height: u32 = 0, // h
    left_edge: u32 = 0, // X
    top_edge: u32 = 0, // Y
    composition_mode: CompositionMode = .alpha_blend, // C
};

pub const AnimationControl = struct {
    action: AnimationAction = .invalid, // s
    frame: u32 = 0, // r
    gap_ms: u32 = 0, // z
    current_frame: u32 = 0, // c
    loops: u32 = 0, // v

    pub const AnimationAction = enum {
        stop, // 1
        run_wait, // 2
        run, // 3
    };
};

pub const Delete = union(enum) {
    // a/A
    all: bool,

    // i/I
    id: struct {
        delete: bool = false, // uppercase
        image_id: u32 = 0, // i
        placement_id: u32 = 0, // p
    },

    // n/N
    newest: struct {
        delete: bool = false, // uppercase
        count: u32 = 0, // I
        placement_id: u32 = 0, // p
    },

    // c/C,
    intersect_cursor: bool,

    // f/F
    animation_frames: bool,

    // p/P
    intersect_cell: struct {
        delete: bool = false, // uppercase
        x: u32 = 0, // x
        y: u32 = 0, // y
    },

    // q/Q
    intersect_cell_z: struct {
        delete: bool = false, // uppercase
        x: u32 = 0, // x
        y: u32 = 0, // y
        z: u32 = 0, // z
    },

    // x/X
    column: struct {
        delete: bool = false, // uppercase
        x: u32 = 0, // x
    },

    // y/Y
    row: struct {
        delete: bool = false, // uppercase
        y: u32 = 0, // y
    },

    // z/Z
    z: struct {
        delete: bool = false, // uppercase
        z: u32 = 0, // z
    },
};

pub const CompositionMode = enum {
    alpha_blend, // 0
    overwrite, // 1
};
