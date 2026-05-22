// tf_absl_flag_guard.h
//
// conda-forge tensorflow-feedstock: systemlib (shared) abseil flag guard,
// force-included (via --per_file_copt in build_common.sh) into the few
// translation units that define an ABSL_FLAG.
//
// TensorFlow's pywrap+systemlib megabuild ships both libtensorflow_framework.so
// and libtensorflow_cc.so in the wheel, and the _pywrap_*.so python extensions
// link both. TF's cc_shared_library normally partitions each translation unit
// into exactly one of those shared objects, but the systemlib force-linking
// (see build_common.sh) defeats that partitioning, so the same static
// ABSL_FLAG(...) definitions get embedded into BOTH libraries.
//
// With conda's *shared* libabseil there is exactly ONE process-global
// absl::flags FlagRegistry. When the second TF .so loads, its ABSL_FLAG static
// initializer re-registers a flag name the first .so already registered, and
// absl aborts `import tensorflow`:
//
//   ERROR: Flag 'coordination_agent_recoverable' was defined more than once
//   ERROR: Flag 'leave_barriers_on_recoverable_agent_restart' ...
//
// Unlike TF's own duplicate-registration aborts (proto descriptors, OpRegistry,
// the stream_executor PlatformObjectRegistry) we cannot patch absl to tolerate
// the duplicate -- it is a prebuilt conda package. Instead we make the flag
// definitions stop registering, while still defining FLAGS_<name> so
// absl::GetFlag(FLAGS_<name>) keeps working.
//
// Mechanism: abseil's ABSL_FLAG -> ABSL_FLAG_IMPL emits, as its last step,
//   absl::flags_internal::FlagRegistrar<T, /*do_register=*/true>(&FLAGS_x, file)
// whose constructor is `if (do_register) RegisterCommandLineFlag(...)`. abseil's
// own ABSL_FLAGS_STRIP_NAMES build already uses the <T, false> form (no
// registration). We include absl/flags/flag.h and then override just the
// ABSL_FLAG_IMPL_REGISTRAR sub-macro to force do_register=false. This keeps the
// flag's name/help/value (no -DABSL_FLAGS_STRIP_NAMES name stripping) and keeps
// the chainable .OnUpdate(); only the FlagRegistry insertion is skipped, so the
// duplicate registration across the two .so's is silently a no-op.
//
// The override must happen AFTER flag.h defines ABSL_FLAG_IMPL_REGISTRAR, so we
// include flag.h here (rather than redefining a token, like the proto guard).
// Self-guarded to C++ non-CUDA TUs (skip C: no __cplusplus, and every nvcc
// pass: __CUDACC__) so that even though it is only applied to known
// ABSL_FLAG-defining .cc files today, it stays a no-op if force-included
// elsewhere. Installed into $PREFIX/include so the bare-name -include
// resolves; removed before packaging.

#ifndef TF_ABSL_FLAG_GUARD_H_
#define TF_ABSL_FLAG_GUARD_H_

#if defined(__cplusplus) && !defined(__CUDACC__)

#include "absl/flags/flag.h"

#ifdef ABSL_FLAG_IMPL_REGISTRAR
#undef ABSL_FLAG_IMPL_REGISTRAR
// Force do_register=false: define FLAGS_<name> (so GetFlag still works) but do
// not insert it into the process-global absl FlagRegistry, which otherwise
// aborts when the same flag-defining TU is loaded from more than one TF .so.
#define ABSL_FLAG_IMPL_REGISTRAR(T, flag)                       \
  absl::flags_internal::FlagRegistrar<T, /*do_register=*/false>( \
      ABSL_FLAG_IMPL_FLAG_PTR(flag), ABSL_FLAG_IMPL_FILENAME())
#endif  // ABSL_FLAG_IMPL_REGISTRAR

#endif  // __cplusplus && !__CUDACC__

#endif  // TF_ABSL_FLAG_GUARD_H_
