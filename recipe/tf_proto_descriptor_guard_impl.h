// tf_proto_descriptor_guard_impl.h
//
// conda-forge tensorflow-feedstock: systemlib (shared) protobuf guard,
// implementation part, force-included (via --per_file_copt) into the
// generated .pb.cc files ONLY (they already pull the heavy protobuf/absl
// C++17 headers it needs). See tf_proto_descriptor_guard.h for the rationale.
//
// AddDescriptors_TfGuarded below is a functional clone of protobuf 6.33.x's
// google::protobuf::internal::AddDescriptors (no absl::call_once -- the
// DescriptorTable::once flag belongs to the lazy AssignDescriptors(); static
// init is single-threaded so the is_initialized self-check suffices). The one
// behavioural change: skip InternalAddGeneratedFile() (the call that aborts on
// a duplicate) when the file is already in the process-global database, while
// still setting up this .so's defaults and MessageFactory entry.

#ifndef TF_PROTO_DESCRIPTOR_GUARD_IMPL_H_
#define TF_PROTO_DESCRIPTOR_GUARD_IMPL_H_

#if defined(__cplusplus)

// Undefine the AddDescriptors redirect macro while parsing this header so the
// protobuf headers below use their real names; it is re-installed at the end.
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
// comment). inline => merged to one copy per shared object.
inline void AddDescriptors_TfGuarded(const DescriptorTable* table) {
  // Per-.so idempotency, exactly like the real AddDescriptors.
  if (table->is_initialized) {
    return;
  }
  table->is_initialized = true;

  // Ensure default fields are initialised (reflection refers to them).
  InitProtobufDefaults();
  InitializeFileDescriptorDefaultInstances();

  // Register dependency files first, through the guarded path.
  for (int i = 0; i < table->num_deps; ++i) {
    if (table->deps[i] != nullptr) {
      AddDescriptors_TfGuarded(table->deps[i]);
    }
  }

  // The one guarded step: only add the encoded file to the process-global
  // database if not already there (a second .so re-registering it is what
  // aborts). FindFileByName is a pure lookup -- it never builds or aborts.
  bool already_registered = false;
  DescriptorDatabase* db = DescriptorPool::internal_generated_database();
  if (db != nullptr) {
    FileDescriptorProto existing;
    already_registered = db->FindFileByName(table->filename, &existing);
  }
  if (!already_registered) {
    DescriptorPool::InternalAddGeneratedFile(table->descriptor, table->size);
    // Register the factory entry only when this .so is the first to register
    // the file (single owner). Other .so's reflect fine: reflection is
    // assigned lazily by AssignDescriptors() off the shared generated pool.
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
