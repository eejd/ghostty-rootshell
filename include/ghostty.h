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

// Opaque types
typedef void *ghostty_app_t;
typedef void *ghostty_config_t;

//-------------------------------------------------------------------
// Published API

int ghostty_init(void);

ghostty_config_t ghostty_config_new();
void ghostty_config_free(ghostty_config_t);
void ghostty_config_load_string(ghostty_config_t, const char *, uintptr_t);
void ghostty_config_finalize(ghostty_config_t);

ghostty_app_t ghostty_app_new(ghostty_runtime_config_s *, ghostty_config_t);
void ghostty_app_free(ghostty_app_t);
int ghostty_app_tick(ghostty_app_t);

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_H */
