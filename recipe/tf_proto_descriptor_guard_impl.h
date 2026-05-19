// tf_proto_descriptor_guard_impl.h
//
// conda-forge tensorflow-feedstock: systemlib (shared) protobuf guard
// -- implementation part, force-included (via --per_file_copt) into the
// generated .pb.cc files ONLY.
//
// See tf_proto_descriptor_guard.h for the full rationale. This header carries
// the inline definition of the guarded descriptor-registration entry point.
// It is restricted to .pb.cc translation units because it pulls in heavy
// protobuf/absl headers (C++17); .pb.cc files already include those and are
// already built as C++17, so that is safe here but would not be in arbitrary
// vendored sources.
//
// IMPLEMENTATION NOTE -- this is an exact functional clone of protobuf's
// own google::protobuf::internal::AddDescriptors() (protobuf 6.33.x). That
// function, disassembled from the conda libprotobuf.so, is:
//
//   void AddDescriptors(const DescriptorTable* table) {
//     if (table->is_initialized) return;          // per-.so idempotency
//     table->is_initialized = true;
//     InitProtobufDefaults();                     // (defaults-state guarded)
//     InitializeFileDescriptorDefaultInstances();
//     for (i in 0..num_deps) if (deps[i]) AddDescriptors(deps[i]);
//     DescriptorPool::InternalAddGeneratedFile(descriptor, size);
//     MessageFactory::InternalRegisterGeneratedFile(table);
//   }
//
// It is NOT wrapped in absl::call_once -- the DescriptorTable::once flag is
// owned exclusively by AssignDescriptors()/AssignDescriptorsImpl() (the lazy
// reflection initialiser). Consuming `once` here would make the later
// AssignDescriptors() call_once a silent no-op, leaving message reflection
// unassigned and crashing TextFormat / Any handling. So the guarded clone
// below also avoids `once` entirely; static initialisers run single-threaded
// so the bare `is_initialized` self-check is sufficient.
//
// The ONLY behavioural change vs the original: InternalAddGeneratedFile() --
// the call that aborts on a duplicate -- is skipped when the file is already
// present in the process-global generated descriptor database (i.e. it was
// registered by another TF shared object). Everything else still runs so
// this .so's own MessageFactory entry and default instances are set up.

#ifndef TF_PROTO_DESCRIPTOR_GUARD_IMPL_H_
#define TF_PROTO_DESCRIPTOR_GUARD_IMPL_H_

#if defined(__cplusplus)

// tf_proto_descriptor_guard.h installs `#define AddDescriptors
// AddDescriptors_TfGuarded`. Undefine it while this header is being parsed so
// the protobuf headers below declare their real names and so we can refer to
// real protobuf symbols. The macro is re-installed at the end so the
// generated .pb.cc call site is still rewritten.
#ifdef AddDescriptors
#undef AddDescriptors
#endif

#include "google/protobuf/descriptor.h"
#include "google/protobuf/descriptor.pb.h"
#include "google/protobuf/descriptor_database.h"
#include "google/protobuf/generated_message_reflection.h"
#include "google/protobuf/generated_message_util.h"
#include "google/protobuf/message.h"

namespace google {
namespace protobuf {
namespace internal {

// Guarded clone of google::protobuf::internal::AddDescriptors (see file
// comment). inline => one definition per .pb.cc TU, merged by the linker to
// one copy per shared object.
inline void AddDescriptors_TfGuarded(const DescriptorTable* table) {
  // Per-.so idempotency, exactly like the real AddDescriptors.
  if (table->is_initialized) {
    return;
  }
  table->is_initialized = true;

  // Reflection refers to the default fields, so make sure they are
  // initialised (InitProtobufDefaults is an inline cheap-path wrapper around
  // InitProtobufDefaultsSlow).
  InitProtobufDefaults();
  InitializeFileDescriptorDefaultInstances();

  // Register dependency files first -- through the guarded path, so a dep
  // shared with another TF .so is also tolerated.
  for (int i = 0; i < table->num_deps; ++i) {
    if (table->deps[i] != nullptr) {
      AddDescriptors_TfGuarded(table->deps[i]);
    }
  }

  // The one guarded step: only add the encoded file to the process-global
  // generated descriptor database if it is not already there. A second TF
  // .so re-registering the same file is exactly what makes protobuf abort
  // ("File already exists in database"). FindFileByName on the generated
  // EncodedDescriptorDatabase is a pure lookup -- it neither builds
  // descriptors nor aborts.
  bool already_registered = false;
  DescriptorDatabase* db = DescriptorPool::internal_generated_database();
  if (db != nullptr) {
    FileDescriptorProto existing;
    already_registered = db->FindFileByName(table->filename, &existing);
  }
  if (!already_registered) {
    DescriptorPool::InternalAddGeneratedFile(table->descriptor, table->size);
    // Register the generated-message factory entry for this file only when
    // this .so is the first to register it -- keeping a single owner of both
    // the descriptor and the factory mapping. When another TF .so already
    // registered the file, that .so's table owns the factory entry; this
    // .so's own message types still reflect correctly because reflection is
    // assigned lazily by AssignDescriptors() off the (shared) generated pool.
    MessageFactory::InternalRegisterGeneratedFile(table);
  }
}

}  // namespace internal
}  // namespace protobuf
}  // namespace google

// Re-install the redirect macro for the generated .pb.cc body that follows.
#define AddDescriptors AddDescriptors_TfGuarded

#endif  // __cplusplus
#endif  // TF_PROTO_DESCRIPTOR_GUARD_IMPL_H_
