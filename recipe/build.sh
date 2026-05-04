#!/bin/bash

set -ex

# See https://github.com/conda-forge/bazel-feedstock/issues/273
find $BUILD_PREFIX/share/bazel/install | xargs -n 1 touch -mt 203601010101

# In abseil-cpp 20260107, the template aliases absl::Nonnull<T>, absl::Nullable<T>,
# and absl::NullabilityUnknown<T> were removed. TF 2.19.1 still uses them in many
# files. Patch the installed header to re-add the aliases as backward-compat no-ops.
python3 - << 'PYEOF'
import os, sys
path = os.path.join(os.environ["BUILD_PREFIX"], "include", "absl", "base", "nullability.h")
with open(path, "r") as f:
    content = f.read()
if "using Nonnull" not in content:
    compat = (
        "\n// Backward-compat aliases removed in abseil-cpp 20260107.\n"
        "namespace absl {\n"
        "template <typename T> using Nonnull = T;\n"
        "template <typename T> using Nullable = T;\n"
        "template <typename T> using NullabilityUnknown = T;\n"
        "}  // namespace absl\n"
    )
    with open(path, "a") as f:
        f.write(compat)
    print(f"Patched {path}")
else:
    print(f"Already has Nonnull alias, skipping patch of {path}")
PYEOF

for ver in 3.9 3.10 3.11 3.12; do
  export PY_VER=$ver
  echo "Building for $PY_VER"
  date
  # let bazel download python headers first
  bash $RECIPE_DIR/build_common.sh || true
  output_base=$(bazel info output_base)
  python_h_path=$(find $output_base/external -wholename "*/python${PY_VER}/Python.h" 2>/dev/null || true)
  rm -rf $PREFIX/include/python
  # copy the bazel downloaded headers to PREFIX
  if [[ -n "$python_h_path" ]]; then
    cp -r $(dirname $python_h_path) $PREFIX/include/python
  fi
  bash $RECIPE_DIR/build_common.sh
  rm -rf $PREFIX/include/python
done

bazel clean
