#!/bin/bash
# Staging build script for the tensorflow-build staging output.
# Runs the full Bazel compilation (build.sh) then installs ALL artifacts
# to $PREFIX so that inheriting outputs can select their files via
# build.files without re-running the build.
#
# Produced artifacts in $PREFIX:
#   lib/libtensorflow.so*           (C API library)
#   lib/libtensorflow_framework.so* (framework library)
#   lib/libtensorflow_cc.so*        (C++ API library)
#   include/tensorflow/c/**         (C API headers)
#   include/tensorflow/cc/**        (C++ API headers, from cc_output)
#   include/xla/**                  (XLA headers, flattened)
#   include/external/**             (original nested include tree)
#
# Python wheels for all versions are left in $SRC_DIR/tensorflow_pkg/
# and picked up by the tensorflow-base inheriting output.

set -ex

bash "$RECIPE_DIR/build.sh"

mkdir -p "${PREFIX}/lib" "${PREFIX}/include"

# libtensorflow.tar.gz: libtensorflow.so*, libtensorflow_framework.so*, C API headers
tar -C "${PREFIX}" -xzf "${SRC_DIR}/libtensorflow.tar.gz"

# libtensorflow_cc_output.tar: libtensorflow_cc.so*, libtensorflow_framework.so*, all headers
tar -C "${PREFIX}" -xf "${SRC_DIR}/libtensorflow_cc_output.tar"

# Flatten XLA headers from nested external path to top-level include/xla/
rsync -av "${PREFIX}/include/external/local_xla/xla/" "${PREFIX}/include/xla/"

# Make shared libraries writable for patchelf (run by rattler-build post-processing)
chmod u+w "${PREFIX}"/lib/libtensorflow*
