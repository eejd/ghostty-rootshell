// Generates code for every target that this compiler can support.
#undef HWY_TARGET_INCLUDE
#define HWY_TARGET_INCLUDE "simd/vt.cpp"  // this file
#include <hwy/foreach_target.h>           // must come before highway.h
#include <hwy/highway.h>
#include <hwy/print-inl.h>

#include <cassert>

HWY_BEFORE_NAMESPACE();
namespace ghostty {
namespace HWY_NAMESPACE {

namespace hn = hwy::HWY_NAMESPACE;

using T = uint32_t;

extern "C" int8_t ghostty_ziglyph_codepoint_width(uint32_t);

HWY_ALIGN T eaw_gte[] = {
    0x3000,  0xff01,  0xffe0,  0x1100,  0x231a,  0x2329,  0x232a,  0x23e9,
    0x23f0,  0x25f3,  0x25fd,  0x2614,  0x2648,  0x267f,  0x2693,  0x26a1,
    0x26aa,  0x26bd,  0x26c4,  0x26ce,  0x26d4,  0x26ea,  0x26f2,  0x26f5,
    0x26fa,  0x26fd,  0x2705,  0x270a,  0x2728,  0x274c,  0x274e,  0x2753,
    0x2757,  0x2795,  0x27b0,  0x27bf,  0x2b1b,  0x2b50,  0x2b55,  0x2e80,
    0x2e9b,  0x2f00,  0x2ff0,  0x3001,  0x302e,  0x3041,  0x309b,  0x309d,
    0x309f,  0x30a0,  0x30a1,  0x30fb,  0x30fc,  0x30ff,  0x3105,  0x3131,
    0x3190,  0x3192,  0x3196,  0x31a0,  0x31c0,  0x31f0,  0x3200,  0x3220,
    0x322a,  0x3250,  0x3251,  0x3260,  0x3280,  0x328a,  0x32b1,  0x32c0,
    0x3400,  0x4e00,  0xa015,  0xa016,  0xa490,  0xa960,  0xac00,  0xf900,
    0xfa70,  0xfe10,  0xfe30,  0xfe54,  0xfe68,  0x16fe0, 0x16ff0, 0x17000,
    0x18800, 0x18d00, 0x1aff0, 0x1aff5, 0x1affd, 0x1b000, 0x1b132, 0x1b150,
    0x1b155, 0x1b164, 0x1b170, 0x1f004, 0x1f0cf, 0x1f18e, 0x1f191, 0x1f200,
    0x1f210, 0x1f240, 0x1f250, 0x1f260, 0x1f300, 0x1f32d, 0x1f337, 0x1f37e,
    0x1f3a0, 0x1f3cf, 0x1f3e0, 0x1f3f4, 0x1f3f8, 0x1f3fb, 0x1f400, 0x1f440,
    0x1f442, 0x1f4ff, 0x1f54b, 0x1f550, 0x1f57a, 0x1f595, 0x1f5a4, 0x1f5fb,
    0x1f680, 0x1f6cc, 0x1f6d0, 0x1f6d5, 0x1f6dc, 0x1f6eb, 0x1f6f4, 0x1f7e0,
    0x1f7f0, 0x1f90c, 0x1f93c, 0x1f947, 0x1fa70, 0x1fa80, 0x1fa90, 0x1fabf,
    0x1face, 0x1fae0, 0x1faf0, 0x20000, 0x2a700, 0x2b740, 0x2b820, 0x2ceb0,
    0x2f800, 0x30000, 0x31350, 0,       0,       0,       0,       0,
    0,       0,       0,       0,       0,       0,       0,       0,
    0,       0,       0,       0,       0,       0,       0,       0,
};

HWY_ALIGN T eaw_lte[] = {
    0x3000,  0xff60,  0xffe6,  0x115f,  0x231b,  0x2329,  0x232a,  0x23ec,
    0x23f0,  0x23f3,  0x25fe,  0x2615,  0x2653,  0x267f,  0x2693,  0x26a1,
    0x26ab,  0x26be,  0x26c5,  0x26ce,  0x26d4,  0x26ea,  0x26f3,  0x26f5,
    0x26fa,  0x26fd,  0x2705,  0x270b,  0x2728,  0x274c,  0x274e,  0x2755,
    0x2757,  0x2797,  0x27b0,  0x27bf,  0x2b1c,  0x2b50,  0x2b55,  0x2e99,
    0x2ef3,  0x2fd5,  0x2ffb,  0x3029,  0x303e,  0x3096,  0x309c,  0x309e,
    0x309f,  0x30a0,  0x30fa,  0x30fb,  0x30fe,  0x30ff,  0x312f,  0x318e,
    0x3191,  0x3195,  0x319f,  0x31bf,  0x31e3,  0x31ff,  0x321e,  0x3229,
    0x3247,  0x3250,  0x325f,  0x327f,  0x3289,  0x32b0,  0x32bf,  0x33ff,
    0x4bdf,  0xa014,  0xa015,  0xa48c,  0xa4c6,  0xa97c,  0xd7a3,  0xfa6d,
    0xfad9,  0xfe19,  0xfe52,  0xfe66,  0xfe6b,  0x16fe3, 0x16ff1, 0x187f7,
    0x18cd5, 0x18d08, 0x1aff3, 0x1affb, 0x1affe, 0x1b122, 0x1b132, 0x1b152,
    0x1b155, 0x1b167, 0x1b2fb, 0x1f004, 0x1f0cf, 0x1f18e, 0x1f19a, 0x1f202,
    0x1f23b, 0x1f248, 0x1f251, 0x1f265, 0x1f320, 0x1f335, 0x1f37c, 0x1f393,
    0x1f3ca, 0x1f3d3, 0x1f3f0, 0x1f3f4, 0x1f3fa, 0x1f3ff, 0x1f43e, 0x1f440,
    0x1f4fc, 0x1f53d, 0x1f54e, 0x1f567, 0x1f57a, 0x1f596, 0x1f5a4, 0x1f64f,
    0x1f6c5, 0x1f6cc, 0x1f6d2, 0x1f6d7, 0x1f6df, 0x1f6ec, 0x1f6fc, 0x1f7eb,
    0x1f7f0, 0x1f93a, 0x1f945, 0x1f9ff, 0x1fa7c, 0x1fa88, 0x1fabd, 0x1fac5,
    0x1fadb, 0x1fae8, 0x1faf8, 0x2a6df, 0x2b739, 0x2b81d, 0x2cea1, 0x2ebe0,
    0x2fa1d, 0x3134a, 0x323af, 0,       0,       0,       0,       0,
    0,       0,       0,       0,       0,       0,       0,       0,
    0,       0,       0,       0,       0,       0,       0,       0,
};

template <class D>
int8_t CodepointWidthImpl(D d, T input) {
  // If the input is ASCII, then we return 1. We do NOT check for
  // control characters because we assume that the input has already
  // been checked for that case.
  if (input < 0xFF) {
    return 1;
  }

  // Its not ASCII, so lets move to vector ops to figure out the width.
  const size_t N = hn::Lanes(d);
  const hn::Vec<D> input_vec = Set(d, input);

  {
    // Thes are the ranges (inclusive) of the codepoints that are DEFINITELY
    // width 2. We will check as many in parallel as possible.
    //
    // The zero padding is so that we can always load aligned directly into
    // a vector register of any size up to 16 bytes (AVX512).
    //
    // Ranges: two-em dash, gbp.isRegionalIndicator, CJK...
    HWY_ALIGN T gte_keys[] = {
        0x2E3A, 0x1f1e6, 0x3400, 0x4E00, 0xF900, 0x20000, 0x30000, 0,
        0,      0,       0,      0,      0,      0,       0,       0,
    };
    HWY_ALIGN T lte_keys[] = {
        0x2E3A, 0x1f1ff, 0x4DBF, 0x9FFF, 0xFAFF, 0x2FFFD, 0x3FFFD, 0,
        0,      0,       0,      0,      0,      0,       0,       0,
    };
    size_t i = 0;
    for (; i + N <= std::size(lte_keys) && lte_keys[i] != 0; i += N) {
      const hn::Vec<D> lte_vec = hn::Load(d, lte_keys + i);
      const hn::Vec<D> gte_vec = hn::Load(d, gte_keys + i);
      const intptr_t idx = hn::FindFirstTrue(
          d, hn::And(hn::Le(input_vec, lte_vec), hn::Ge(input_vec, gte_vec)));
      if (idx >= 0) {
        return 2;
      }
    }
    assert(i >= 7);  // We should have checked all the ranges.
  }

  {
    // Definitely width 0
    HWY_ALIGN T gte_keys[] = {
        0x1160, 0x2060, 0xFFF0, 0xE0000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    };
    HWY_ALIGN T lte_keys[] = {
        0x11FF, 0x206F, 0xFFF8, 0xE0FFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    };
    size_t i = 0;
    for (; i + N <= std::size(lte_keys) && lte_keys[i] != 0; i += N) {
      const hn::Vec<D> lte_vec = hn::Load(d, lte_keys + i);
      const hn::Vec<D> gte_vec = hn::Load(d, gte_keys + i);
      const intptr_t idx = hn::FindFirstTrue(
          d, hn::And(hn::Le(input_vec, lte_vec), hn::Ge(input_vec, gte_vec)));
      if (idx >= 0) {
        return 0;
      }
    }
  }

  if (input >= eaw_lte[0] && input <= 0x323af) {
    size_t i = 0;
    for (; i + N <= std::size(eaw_lte) && eaw_lte[i] != 0; i += N) {
      const hn::Vec<D> lte_vec = hn::Load(d, eaw_lte + i);
      const hn::Vec<D> gte_vec = hn::Load(d, eaw_gte + i);
      const intptr_t idx = hn::FindFirstTrue(
          d, hn::And(hn::Le(input_vec, lte_vec), hn::Ge(input_vec, gte_vec)));
      if (idx >= 0) {
        return 2;
      }
    }
  }

  return ghostty_ziglyph_codepoint_width(input);
}

int8_t CodepointWidth(T input) {
  const hn::ScalableTag<T> d;
  return CodepointWidthImpl(d, input);
}

}  // namespace HWY_NAMESPACE
}  // namespace ghostty
HWY_AFTER_NAMESPACE();

// HWY_ONCE is true for only one of the target passes
#if HWY_ONCE

namespace ghostty {

HWY_EXPORT(CodepointWidth);

int8_t CodepointWidth(uint32_t cp) {
  return HWY_DYNAMIC_DISPATCH(CodepointWidth)(cp);
}

}  // namespace ghostty

extern "C" {

int8_t ghostty_simd_codepoint_width(uint32_t cp) {
  return ghostty::CodepointWidth(cp);
}

}  // extern "C"

#endif  // HWY_ONCE
