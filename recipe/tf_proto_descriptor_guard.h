// tf_proto_descriptor_guard.h
//
// conda-forge tensorflow-feedstock: systemlib (shared) protobuf guard,
// lightweight part, force-included into *every* translation unit.
//
// Many TF .so's each embed the same generated .pb.o, so with shared
// libprotobuf's single process-global descriptor database the second .so to
// load re-registers an already-registered proto file and protobuf aborts
// ("File already exists in database"). This header just installs an
// object-like macro redirecting the generated AddDescriptors() call site to
// AddDescriptors_TfGuarded (defined, for .pb.cc TUs only, by
// tf_proto_descriptor_guard_impl.h, which skips the duplicate registration).
// It must stay featherweight (no protobuf/absl headers) because it is also
// force-included into C and older-std vendored TUs, where only .pb.cc files
// ever reference AddDescriptors so the macro is otherwise inert.

#ifndef TF_PROTO_DESCRIPTOR_GUARD_H_
#define TF_PROTO_DESCRIPTOR_GUARD_H_

// No-op outside C++ (the force-include also reaches C and CUDA TUs).
#if defined(__cplusplus)

// Redirect the generated ::_pbi::AddDescriptors call to AddDescriptors_TfGuarded.
// No declaration here on purpose: TUs that never reference it need none, and
// .pb.cc TUs get the inline definition from tf_proto_descriptor_guard_impl.h.
#define AddDescriptors AddDescriptors_TfGuarded

#endif  // __cplusplus
#endif  // TF_PROTO_DESCRIPTOR_GUARD_H_
