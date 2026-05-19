// tf_proto_descriptor_guard.h
//
// conda-forge tensorflow-feedstock: systemlib (shared) protobuf guard
// -- lightweight part, force-included into *every* translation unit.
//
// TensorFlow ships many shared objects (libtensorflow_framework.so,
// libtensorflow_cc.so, the _pywrap_*.so python extensions, the tflite and
// profiler plugin .so's, ...). Each statically embeds the .pb.o of the same
// generated protobuf descriptors (e.g. tensor_shape.proto).
//
// With conda's *shared* libprotobuf.so there is exactly ONE process-global
// generated-descriptor database. Every .pb.cc has a static initializer that
// calls google::protobuf::internal::AddDescriptors(), which ends in
// DescriptorPool::InternalAddGeneratedFile() -> GeneratedDatabase()->Add().
// When a second TF .so loads, its initializers re-register a proto file the
// first .so already registered, Add() finds it present and protobuf aborts:
//
//   descriptor_database.cc: File already exists in database: <file>.proto
//   descriptor.cc: Check failed: GeneratedDatabase()->Add(...)
//
// Two force-included headers cooperate to fix this WITHOUT giving up shared
// protobuf:
//
//   * THIS header (tf_proto_descriptor_guard.h) is force-included into every
//     TU. It must stay featherweight -- it pulls in NO protobuf/absl headers
//     -- because it is also force-included into translation units built with
//     an older -std or as plain C (e.g. vendored XNNPACK sources). It only
//     installs an object-like macro that rewrites the bare token
//     `AddDescriptors`, redirecting the one generated call site
//       ::_pbi::AddDescriptors(&descriptor_table_<proto>)
//     in every .pb.cc to ::_pbi::AddDescriptors_TfGuarded.
//
//   * tf_proto_descriptor_guard_impl.h is force-included (via --per_file_copt)
//     into the .pb.cc files only. It provides the inline definition of
//     google::protobuf::internal::AddDescriptors_TfGuarded, which queries the
//     process-global generated descriptor database and skips registration of
//     a file already present instead of aborting.
//
// Only generated .pb.cc files call AddDescriptors(); ordinary TF code does
// not (verified across tensorflow/ and third_party/), so the macro has no
// other effect. libprotobuf.so itself is a prebuilt conda package, unaffected.

#ifndef TF_PROTO_DESCRIPTOR_GUARD_H_
#define TF_PROTO_DESCRIPTOR_GUARD_H_

// Only meaningful for C++ compiles. The force-include reaches C and CUDA TUs
// too; guard so it is an absolute no-op there.
#if defined(__cplusplus)

// Object-like macro: rewrites the bare token AddDescriptors, so the generated
// call ::_pbi::AddDescriptors (where _pbi == ::google::protobuf::internal)
// becomes ::_pbi::AddDescriptors_TfGuarded. Intentionally NO declaration of
// the target here -- a TU that never references it needs none, and the .pb.cc
// TUs get the full inline definition from tf_proto_descriptor_guard_impl.h.
#define AddDescriptors AddDescriptors_TfGuarded

#endif  // __cplusplus
#endif  // TF_PROTO_DESCRIPTOR_GUARD_H_
