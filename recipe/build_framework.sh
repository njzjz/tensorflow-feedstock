#!/bin/bash
# Combined script for the libtensorflow_framework output.
# Runs the full Bazel compilation (build.sh) then packages the framework library.
# Artifacts are copied to /tmp/tf_artifacts/ so sibling outputs can find them

set -ex

bash "$RECIPE_DIR/build.sh"

# Share build artifacts with sibling outputs
mkdir -p /tmp/tf_artifacts
cp -a "$SRC_DIR"/libtensorflow.tar.gz /tmp/tf_artifacts/
cp -a "$SRC_DIR"/libtensorflow_cc_output.tar /tmp/tf_artifacts/
cp -a "$SRC_DIR"/tensorflow_pkg /tmp/tf_artifacts/

bash "$RECIPE_DIR/cp_libtensorflow_framework.sh"
