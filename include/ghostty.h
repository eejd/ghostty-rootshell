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

typedef enum {
    GHOSTTY_MODS_NONE  = 0,
    GHOSTTY_MODS_SHIFT = 1 << 0,
    GHOSTTY_MODS_CTRL  = 1 << 1,
    GHOSTTY_MODS_ALT   = 1 << 2,
    GHOSTTY_MODS_SUPER = 1 << 3,
    GHOSTTY_MODS_CAPS  = 1 << 4,
    GHOSTTY_MODS_NUM   = 1 << 5,
} ghostty_input_mods_e;

typedef enum {
    GHOSTTY_ACTION_RELEASE,
    GHOSTTY_ACTION_PRESS,
    GHOSTTY_ACTION_REPEAT,
} ghostty_input_action_e;

typedef enum {
    GHOSTTY_KEY_INVALID,

    // a-z
    GHOSTTY_KEY_A,
    GHOSTTY_KEY_B,
    GHOSTTY_KEY_C,
    GHOSTTY_KEY_D,
    GHOSTTY_KEY_E,
    GHOSTTY_KEY_F,
    GHOSTTY_KEY_G,
    GHOSTTY_KEY_H,
    GHOSTTY_KEY_I,
    GHOSTTY_KEY_J,
    GHOSTTY_KEY_K,
    GHOSTTY_KEY_L,
    GHOSTTY_KEY_M,
    GHOSTTY_KEY_N,
    GHOSTTY_KEY_O,
    GHOSTTY_KEY_P,
    GHOSTTY_KEY_Q,
    GHOSTTY_KEY_R,
    GHOSTTY_KEY_S,
    GHOSTTY_KEY_T,
    GHOSTTY_KEY_U,
    GHOSTTY_KEY_V,
    GHOSTTY_KEY_W,
    GHOSTTY_KEY_X,
    GHOSTTY_KEY_Y,
    GHOSTTY_KEY_Z,

    // numbers
    GHOSTTY_KEY_ZERO,
    GHOSTTY_KEY_ONE,
    GHOSTTY_KEY_TWO,
    GHOSTTY_KEY_THREE,
    GHOSTTY_KEY_FOUR,
    GHOSTTY_KEY_FIVE,
    GHOSTTY_KEY_SIX,
    GHOSTTY_KEY_SEVEN,
    GHOSTTY_KEY_EIGHT,
    GHOSTTY_KEY_NINE,

    // puncuation
    GHOSTTY_KEY_SEMICOLON,
    GHOSTTY_KEY_SPACE,
    GHOSTTY_KEY_APOSTROPHE,
    GHOSTTY_KEY_COMMA,
    GHOSTTY_KEY_GRAVE_ACCENT, // `
    GHOSTTY_KEY_PERIOD,
    GHOSTTY_KEY_SLASH,
    GHOSTTY_KEY_MINUS,
    GHOSTTY_KEY_EQUAL,
    GHOSTTY_KEY_LEFT_BRACKET, // [
    GHOSTTY_KEY_RIGHT_BRACKET, // ]
    GHOSTTY_KEY_BACKSLASH, // /

    // control
    GHOSTTY_KEY_UP,
    GHOSTTY_KEY_DOWN,
    GHOSTTY_KEY_RIGHT,
    GHOSTTY_KEY_LEFT,
    GHOSTTY_KEY_HOME,
    GHOSTTY_KEY_END,
    GHOSTTY_KEY_INSERT,
    GHOSTTY_KEY_DELETE,
    GHOSTTY_KEY_CAPS_LOCK,
    GHOSTTY_KEY_SCROLL_LOCK,
    GHOSTTY_KEY_NUM_LOCK,
    GHOSTTY_KEY_PAGE_UP,
    GHOSTTY_KEY_PAGE_DOWN,
    GHOSTTY_KEY_ESCAPE,
    GHOSTTY_KEY_ENTER,
    GHOSTTY_KEY_TAB,
    GHOSTTY_KEY_BACKSPACE,
    GHOSTTY_KEY_PRINT_SCREEN,
    GHOSTTY_KEY_PAUSE,

    // function keys
    GHOSTTY_KEY_F1,
    GHOSTTY_KEY_F2,
    GHOSTTY_KEY_F3,
    GHOSTTY_KEY_F4,
    GHOSTTY_KEY_F5,
    GHOSTTY_KEY_F6,
    GHOSTTY_KEY_F7,
    GHOSTTY_KEY_F8,
    GHOSTTY_KEY_F9,
    GHOSTTY_KEY_F10,
    GHOSTTY_KEY_F11,
    GHOSTTY_KEY_F12,
    GHOSTTY_KEY_F13,
    GHOSTTY_KEY_F14,
    GHOSTTY_KEY_F15,
    GHOSTTY_KEY_F16,
    GHOSTTY_KEY_F17,
    GHOSTTY_KEY_F18,
    GHOSTTY_KEY_F19,
    GHOSTTY_KEY_F20,
    GHOSTTY_KEY_F21,
    GHOSTTY_KEY_F22,
    GHOSTTY_KEY_F23,
    GHOSTTY_KEY_F24,
    GHOSTTY_KEY_F25,

    // keypad
    GHOSTTY_KEY_KP_0,
    GHOSTTY_KEY_KP_1,
    GHOSTTY_KEY_KP_2,
    GHOSTTY_KEY_KP_3,
    GHOSTTY_KEY_KP_4,
    GHOSTTY_KEY_KP_5,
    GHOSTTY_KEY_KP_6,
    GHOSTTY_KEY_KP_7,
    GHOSTTY_KEY_KP_8,
    GHOSTTY_KEY_KP_9,
    GHOSTTY_KEY_KP_DECIMAL,
    GHOSTTY_KEY_KP_DIVIDE,
    GHOSTTY_KEY_KP_MULTIPLY,
    GHOSTTY_KEY_KP_SUBTRACT,
    GHOSTTY_KEY_KP_ADD,
    GHOSTTY_KEY_KP_ENTER,
    GHOSTTY_KEY_KP_EQUAL,

    // modifiers
    GHOSTTY_KEY_LEFT_SHIFT,
    GHOSTTY_KEY_LEFT_CONTROL,
    GHOSTTY_KEY_LEFT_ALT,
    GHOSTTY_KEY_LEFT_SUPER,
    GHOSTTY_KEY_RIGHT_SHIFT,
    GHOSTTY_KEY_RIGHT_CONTROL,
    GHOSTTY_KEY_RIGHT_ALT,
    GHOSTTY_KEY_RIGHT_SUPER,
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
void ghostty_surface_set_focus(ghostty_surface_t, bool);
void ghostty_surface_set_size(ghostty_surface_t, uint32_t, uint32_t);
void ghostty_surface_key(ghostty_surface_t, ghostty_input_action_e, ghostty_input_key_e, ghostty_input_mods_e);
void ghostty_surface_char(ghostty_surface_t, uint32_t);

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_H */
