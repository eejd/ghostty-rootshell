// Workaround for:
// https://github.com/ziglang/zig/issues/13598

#include <objc/message.h>
#include <objc/runtime.h>

// From Metal.h
typedef struct Origin {
    unsigned long x;
    unsigned long y;
    unsigned long z;
} Origin;

typedef struct Size {
    unsigned long width;
    unsigned long height;
    unsigned long depth;
} Size;

typedef struct MTLRegion {
    Origin origin;
    Size size;
} MTLRegion;

void ghostty_metal_replaceregion(
    id target,
    SEL sel,
    MTLRegion region,
    unsigned long offset,
    void *ptr,
    unsigned long len
) {
    void (*replaceRegion)(id, SEL, MTLRegion, unsigned long, void *, unsigned long) = (void (*)(id, SEL, MTLRegion, unsigned long, void *, unsigned long)) objc_msgSend;
    replaceRegion(target, sel, region, offset, ptr, len);
}
