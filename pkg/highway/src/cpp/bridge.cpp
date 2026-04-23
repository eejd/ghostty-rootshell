#include <hwy/abort.h>
#include <hwy/base.h>
#include <hwy/targets.h>

#include <stdint.h>

namespace hwy {
namespace {

// Highway's upstream abort.cc pulls in libc++ even when the rest of the
// library is compiled with HWY_NO_LIBCXX. Ghostty only needs Highway's dynamic
// dispatch/runtime target selection, so we provide the tiny Warn/Abort surface
// that targets.cc/per_target.cc expect and keep the package free of libc++.
WarnFunc g_warn_func = nullptr;
AbortFunc g_abort_func = nullptr;

}  // namespace

WarnFunc& GetWarnFunc() {
  return g_warn_func;
}

AbortFunc& GetAbortFunc() {
  return g_abort_func;
}

WarnFunc SetWarnFunc(WarnFunc func) {
  // Highway documents these setters as thread-safe. Using the compiler builtin
  // keeps that guarantee without depending on std::atomic.
  return __atomic_exchange_n(&g_warn_func, func, __ATOMIC_SEQ_CST);
}

AbortFunc SetAbortFunc(AbortFunc func) {
  return __atomic_exchange_n(&g_abort_func, func, __ATOMIC_SEQ_CST);
}

void Warn(const char* file, int line, const char* format, ...) {
  if (WarnFunc func = __atomic_load_n(&g_warn_func, __ATOMIC_SEQ_CST)) {
    func(file, line, format);
  }
}

HWY_NORETURN void Abort(const char* file, int line, const char* format, ...) {
  if (AbortFunc func = __atomic_load_n(&g_abort_func, __ATOMIC_SEQ_CST)) {
    func(file, line, format);
  }

  __builtin_trap();
}

}  // namespace hwy

extern "C" {

// Zig reads HWY_SUPPORTED_TARGETS via this C shim so it can keep its target
// enum in sync with the vendored Highway build without parsing C++ headers.
int64_t hwy_supported_targets() {
  return HWY_SUPPORTED_TARGETS;
}
}
