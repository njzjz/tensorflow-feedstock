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
// ABSL_FLAG_IMPL_REGISTRAR sub-macro to force do_register=false (the form
// abseil itself uses under ABSL_FLAGS_STRIP_NAMES): FLAGS_<name> is still
// defined so GetFlag works, only the FlagRegistry insertion is skipped.
// Including flag.h is required so the override lands after that macro exists.
// Self-guarded to C++ non-CUDA TUs so it stays a no-op if force-included
// elsewhere; installed into $PREFIX/include for bare-name -include, removed
// before packaging.

#ifndef TF_ABSL_FLAG_GUARD_H_
#define TF_ABSL_FLAG_GUARD_H_

#if defined(__cplusplus) && !defined(__CUDACC__)

#include "absl/flags/flag.h"

#ifdef ABSL_FLAG_IMPL_REGISTRAR
#undef ABSL_FLAG_IMPL_REGISTRAR
// Force do_register=false: define FLAGS_<name> but skip the FlagRegistry
// insertion that aborts when the same flag TU loads from >1 TF .so.
#define ABSL_FLAG_IMPL_REGISTRAR(T, flag)                       \
  absl::flags_internal::FlagRegistrar<T, /*do_register=*/false>( \
      ABSL_FLAG_IMPL_FLAG_PTR(flag), ABSL_FLAG_IMPL_FILENAME())
#endif  // ABSL_FLAG_IMPL_REGISTRAR

#endif  // __cplusplus && !__CUDACC__

#endif  // TF_ABSL_FLAG_GUARD_H_
