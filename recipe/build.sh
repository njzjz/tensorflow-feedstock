#!/bin/bash

set -ex

# See https://github.com/conda-forge/bazel-feedstock/issues/273
find $BUILD_PREFIX/share/bazel/install | xargs -n 1 touch -mt 203601010101

for ver in 3.10 3.11 3.12 3.13; do
  export PY_VER=$ver
  echo "Building for $PY_VER"
  date
  # let bazel download python headers first
  bash $RECIPE_DIR/build_common.sh || true
  output_base=$(bazel info output_base)
  python_h_path=$(find $output_base/external -wholename "*/python${PY_VER}/Python.h")
  rm -rf $PREFIX/include/python
  # copy the bazel downloaded headers to PREFIX
  cp -r $(dirname $python_h_path) $PREFIX/include/python
  bash $RECIPE_DIR/build_common.sh
  rm -rf $PREFIX/include/python
done
bazel clean

# Bazel unpacks its toolchains/install tree read-only, which blocks
# rattler-build from cleaning build_env for the inheriting outputs. Restore
# write permission so packaging can complete.
chmod -R u+w "${BUILD_PREFIX}" 2>/dev/null || true
