// Ghostty embedding API. The documentation for the embedding API is
// only within the Zig source files that define the implementations. This
// isn't meant to be a general purpose embedding API (yet) so there hasn't
// been documentation or example work beyond that.
//
// The only consumer of this API is the macOS app, but the API is built to
// be more general purpose.
#ifndef GHOSTTY_H
#define GHOSTTY_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

//-------------------------------------------------------------------
// Macros

#define GHOSTTY_SUCCESS 0

// Masks for input modifiers
#define GHOSTTY_INPUT_SHIFT 1
#define GHOSTTY_INPUT_CTRL  2
#define GHOSTTY_INPUT_ALT   4
#define GHOSTTY_INPUT_SUPER 8
#define GHOSTTY_INPUT_CAPS  16
#define GHOSTTY_INPUT_NUM   32

//-------------------------------------------------------------------
// Types

// Fully defined types. This MUST be kept in sync with equivalent Zig
// structs. To find the Zig struct, grep for this type name. The documentation
// for all of these types is available in the Zig source.
typedef void (*ghostty_runtime_wakeup_cb)(void *);

typedef struct {
    void *userdata;
    ghostty_runtime_wakeup_cb wakeup_cb;
} ghostty_runtime_config_s;

typedef struct {
    void *nsview;
    double scale_factor;
} ghostty_surface_config_s;

typedef enum { release, press, repeat } ghostty_input_action_e;
typedef enum {
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
} ghostty_input_key_e;

// Opaque types
typedef void *ghostty_app_t;
typedef void *ghostty_config_t;
typedef void *ghostty_surface_t;

//-------------------------------------------------------------------
// Published API

int ghostty_init(void);

ghostty_config_t ghostty_config_new();
void ghostty_config_free(ghostty_config_t);
void ghostty_config_load_string(ghostty_config_t, const char *, uintptr_t);
void ghostty_config_finalize(ghostty_config_t);

ghostty_app_t ghostty_app_new(const ghostty_runtime_config_s *, ghostty_config_t);
void ghostty_app_free(ghostty_app_t);
int ghostty_app_tick(ghostty_app_t);

ghostty_surface_t ghostty_surface_new(ghostty_app_t, ghostty_surface_config_s*);
void ghostty_surface_free(ghostty_surface_t);
void ghostty_surface_refresh(ghostty_surface_t);
void ghostty_surface_set_content_scale(ghostty_surface_t, double, double);
void ghostty_surface_set_size(ghostty_surface_t, uint32_t, uint32_t);
void ghostty_surface_key(ghostty_surface_t, ghostty_input_action_e, ghostty_input_key_e, uint8_t);

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_H */
