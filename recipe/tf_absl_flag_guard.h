// tf_absl_flag_guard.h
//
// conda-forge tensorflow-feedstock: systemlib (shared) abseil flag guard,
// force-included (via --per_file_copt in build_common.sh) into the few TUs
// that define an ABSL_FLAG.
//
// The systemlib megabuild embeds the same ABSL_FLAG definitions into both
// libtensorflow_framework.so and libtensorflow_cc.so, so the second .so to
// load re-registers a flag in shared libabseil's single process-global
// FlagRegistry and absl aborts `import tensorflow` ("Flag ... defined more
// than once"). absl is a prebuilt conda package and cannot be patched like
// TF's own duplicate-registration aborts, so instead we override abseil's
// ABSL_FLAG_IMPL_REGISTRAR sub-macro with a dedup registrar: the FIRST
// registration of a name proceeds normally (the flag stays discoverable and
// settable via absl reflection / ParseCommandLine -- both for flags built
// into only one binary, e.g. the tool TUs, and for the first-loaded TF .so),
// and only a subsequent identically-named registration skips the
// FlagRegistry insertion that would abort. FLAGS_<name> is still defined in
// every copy, so absl::GetFlag on the local object always works.
//
// Caveat (inherent to the duplicated-TU layout, not to this guard): when a
// flag TU lives in two .so's, name-based lookups (ParseCommandLine,
// SetFlag-by-name) reach the first-loaded copy's storage only; code in the
// other .so reading its own FLAGS_<name> object sees that object's value.
// Identical defaults make this invisible unless a flag is set at runtime.
//
// Including flag.h is required so the override lands after that macro
// exists. Self-guarded to C++ non-CUDA TUs so it stays a no-op if
// force-included elsewhere; installed into $PREFIX/include for bare-name
// -include, removed before packaging.

#ifndef TF_ABSL_FLAG_GUARD_H_
#define TF_ABSL_FLAG_GUARD_H_

#if defined(__cplusplus) && !defined(__CUDACC__)

#include <utility>

#include "absl/flags/flag.h"
#include "absl/flags/reflection.h"

#ifdef ABSL_FLAG_IMPL_REGISTRAR
#undef ABSL_FLAG_IMPL_REGISTRAR

namespace tf_absl_flag_guard {

template <typename T>
inline absl::Flag<T>& Deref(absl::Flag<T>& flag) {
  return flag;
}
template <typename T>
inline absl::Flag<T>& Deref(absl::Flag<T>* flag) {
  return *flag;
}

// Register `flag` unless an identically named flag is already present in
// shared libabseil's process-global registry (i.e. the same TU already
// initialized from an earlier-loaded .so). Runs during static init of the
// defining .so; safe because libabseil is a DT_NEEDED dependency (its
// initializers run first) and the registry is behind absl's own lock.
template <typename T, typename FlagArg>
inline absl::flags_internal::FlagRegistrarEmpty RegisterUnlessDuplicate(
    FlagArg&& flag, const char* filename) {
  const bool duplicate =
      absl::FindCommandLineFlag(
          absl::GetFlagReflectionHandle(Deref(flag)).Name()) != nullptr;
  if (duplicate) {
    return absl::flags_internal::FlagRegistrar<T, /*do_register=*/false>(
        std::forward<FlagArg>(flag), filename);
  }
  return absl::flags_internal::FlagRegistrar<T, /*do_register=*/true>(
      std::forward<FlagArg>(flag), filename);
}

}  // namespace tf_absl_flag_guard

#define ABSL_FLAG_IMPL_REGISTRAR(T, flag)           \
  ::tf_absl_flag_guard::RegisterUnlessDuplicate<T>( \
      ABSL_FLAG_IMPL_FLAG_PTR(flag), ABSL_FLAG_IMPL_FILENAME())
#endif  // ABSL_FLAG_IMPL_REGISTRAR

#endif  // __cplusplus && !__CUDACC__

#endif  // TF_ABSL_FLAG_GUARD_H_
