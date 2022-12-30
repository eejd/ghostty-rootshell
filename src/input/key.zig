const std = @import("std");
const Allocator = std.mem.Allocator;

/// A bitmask for all key modifiers. This is taken directly from the
/// GLFW representation, but we use this generically.
pub const Mods = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _padding: u2 = 0,
};

/// The action associated with an input event.
pub const Action = enum {
    release,
    press,
    repeat,
};

/// The set of keys that can map to keybindings. These have no fixed enum
/// values because we map platform-specific keys to this set. Note that
/// this only needs to accomodate what maps to a key. If a key is not bound
/// to anything and the key can be mapped to a printable character, then that
/// unicode character is sent directly to the pty.
pub const Key = enum {
    invalid,

    // a-z
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    // numbers
    zero,
    one,
    two,
    three,
    four,
    five,
    six,
    seven,
    eight,
    nine,

    // puncuation
    semicolon,
    space,
    apostrophe,
    comma,
    grave_accent, // `
    period,
    slash,
    minus,
    equal,
    left_bracket, // [
    right_bracket, // ]
    backslash, // /

    // control
    up,
    down,
    right,
    left,
    home,
    end,
    insert,
    delete,
    caps_lock,
    scroll_lock,
    num_lock,
    page_up,
    page_down,
    escape,
    enter,
    tab,
    backspace,
    print_screen,
    pause,

    // function keys
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    f25,

    // keypad
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    kp_decimal,
    kp_divide,
    kp_multiply,
    kp_subtract,
    kp_add,
    kp_enter,
    kp_equal,

    // modifiers
    left_shift,
    left_control,
    left_alt,
    left_super,
    right_shift,
    right_control,
    right_alt,
    right_super,

    // To support more keys (there are obviously more!) add them here
    // and ensure the mapping is up to date in the Window key handler.
};
