#include <hwy/base.h>
#include <hwy/detect_targets.h>
#include <hwy/highway.h>
#include <hwy/targets.h>

namespace hwy {

extern "C" int64_t ghostty_hwy_detect_targets();

static int64_t DetectTargets() {
  int64_t bits = HWY_SCALAR | HWY_EMU128;

#if (HWY_ARCH_X86 || HWY_ARCH_ARM) && HWY_HAVE_RUNTIME_DISPATCH
  bits |= ghostty_hwy_detect_targets();
#else
  bits |= HWY_ENABLED_BASELINE;
#endif

  if ((bits & HWY_ENABLED_BASELINE) != HWY_ENABLED_BASELINE) {
    const uint64_t bits_u = static_cast<uint64_t>(bits);
    const uint64_t enabled = static_cast<uint64_t>(HWY_ENABLED_BASELINE);
    HWY_WARN("CPU supports 0x%08x%08x, software requires 0x%08x%08x\n",
             static_cast<uint32_t>(bits_u >> 32),
             static_cast<uint32_t>(bits_u & 0xFFFFFFFF),
             static_cast<uint32_t>(enabled >> 32),
             static_cast<uint32_t>(enabled & 0xFFFFFFFF));
  }

  return bits;
}

static int64_t supported_targets_for_test_ = 0;
static int64_t supported_mask_ = LimitsMax<int64_t>();

HWY_DLLEXPORT void DisableTargets(int64_t disabled_targets) {
  supported_mask_ = static_cast<int64_t>(~disabled_targets);
  GetChosenTarget().DeInit();
}

HWY_DLLEXPORT void SetSupportedTargetsForTest(int64_t targets) {
  supported_targets_for_test_ = targets;
  GetChosenTarget().DeInit();
}

HWY_DLLEXPORT int64_t SupportedTargets() {
  int64_t targets = supported_targets_for_test_;
  if (HWY_LIKELY(targets == 0)) {
    targets = DetectTargets();
    GetChosenTarget().Update(targets);
  }

  targets &= supported_mask_;
  return targets == 0 ? HWY_STATIC_TARGET : targets;
}

HWY_DLLEXPORT ChosenTarget& GetChosenTarget() {
  static ChosenTarget chosen_target;
  return chosen_target;
}

}  // namespace hwy
