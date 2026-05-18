#!/bin/bash

set -ex

if [[ "${CI:-}" == "github_actions" ]]; then
  export CPU_COUNT=4
fi

# hmaarrfk - 2025/07/06
# Address incompatibility with newer ABSEL
# Make libprotobuf-python-headers visible for pybind11_protobuf
# These files will be deleted at the end of the build.
mkdir -p $PREFIX/include/python
cp -r $PREFIX/include/google $PREFIX/include/python/
# pybind11_protobuf's proto_api.h includes <Python.h>; make the host
# python headers reachable on the same -I$PREFIX/include/python path.
for _pyinc in $PREFIX/include/python3.*; do
  [ -d "$_pyinc" ] && cp -rn "$_pyinc"/. $PREFIX/include/python/ 2>/dev/null || true
done

cp ${RECIPE_DIR}/pybind11_protobuf/*.patch ${SRC_DIR}/third_party/pybind11_protobuf/.

sed -i.bak "s;@@PREFIX@@;$PREFIX;" third_party/pybind11_protobuf/0002-Add-Python-include-path.patch

# In abseil-cpp 20260107, the template aliases absl::Nonnull<T>, absl::Nullable<T>,
# and absl::NullabilityUnknown<T> were removed. TF 2.19.1 still uses them in many
# files. Patch the installed header to re-add the aliases as backward-compat no-ops.
if [[ ! -f "${SRC_DIR}/nullability_patched" ]]; then
  cat ${RECIPE_DIR}/nullability_deprecated.h >> ${BUILD_PREFIX}/include/absl/base/nullability.h
  cat ${RECIPE_DIR}/nullability_deprecated.h >> ${PREFIX}/include/absl/base/nullability.h
  touch "${SRC_DIR}/nullability_patched"
fi

export PATH="$PWD:$PATH"
export CC=$(basename $CC)
export CXX=$(basename $CXX)
export LIBDIR=$PREFIX/lib
export INCLUDEDIR=$PREFIX/include

export TF_PYTHON_VERSION=$PY_VER

# Upstream docstring for TF_SYSTEM_LIBS in:
# https://github.com/tensorflow/tensorflow/blob/v{{ version }}/third_party/systemlibs/syslibs_configure.bzl
#   * `TF_SYSTEM_LIBS`: list of third party dependencies that should use
#      the system version instead
#
# To avoid bazel installing lots of vendored (python) packages,
# we need to install these packages through meta.yaml and then
# tell bazel to use them. Note that the names don't necessarily
# match PyPI or conda, but are defined in:
# https://github.com/tensorflow/tensorflow/blob/v{{ version }}/tensorflow/workspace<i>.bzl

# Exceptions and TODOs:
# Needs a bazel build:
# com_google_absl
# Build failures in tensorflow/core/platform/s3/aws_crypto.cc
# boringssl (i.e. system openssl)
# Most importantly: Write a patch that uses system LLVM libs for sure as well as MLIR and oneDNN/mkldnn
# TODO(check):
# absl_py
# com_github_googleapis_googleapis
# com_github_googlecloudplatform_google_cloud_cpp
# Needs c++17, try on linux
#  com_googlesource_code_re2
export TF_SYSTEM_LIBS="
  astor_archive
  astunparse_archive
  boringssl
  com_github_googlecloudplatform_google_cloud_cpp
  com_github_grpc_grpc
  com_google_absl
  com_google_protobuf
  curl
  cython
  dill_archive
  flatbuffers
  gast_archive
  gif
  icu
  libjpeg_turbo
  org_sqlite
  png
  pybind11
  snappy
  zlib
  "
# do not build with MKL support
export TF_NEED_MKL=0
export BAZEL_MKL_OPT=""

mkdir -p ./bazel_output_base
export BAZEL_OPTS=""
# Set this to something as otherwise, it would include CFLAGS which itself contains a host path and this then breaks bazel's include path validation.
if [[ "${target_platform}" != *-64 ]]; then
  export CC_OPT_FLAGS="-O2"
elif [[ "${microarch_level}" == "1" ]]; then
  export CC_OPT_FLAGS="-O2 -march=nocona -mtune=haswell"
else
  export CC_OPT_FLAGS="-O2 -march=x86-64-v${microarch_level}"
fi

# Quick debug:
# cp -r ${RECIPE_DIR}/build.sh . && bazel clean && bash -x build.sh --logging=6 | tee log.txt
# Dependency graph:
# bazel query 'deps(//tensorflow/tools/lib_package:libtensorflow)' --output graph > graph.in
if [[ "${target_platform}" == osx-* ]]; then
  export LDFLAGS="${LDFLAGS} -lz -framework CoreFoundation -Xlinker -undefined -Xlinker dynamic_lookup"
else
  # TF 2.21.0's cc_shared_library does not forward the systemlib
  # cc_library linkopts, so the libtensorflow*.so end up with no DT_NEEDED
  # for the systemized third-party libraries they reference:
  # libtensorflow_framework.so's op-generator genrule tools crash dlopen-ing
  # it, and libtensorflow_cc.so fails to link with tens of thousands of
  # undefined symbols (protobuf, grpc, sqlite3, icu, png, jpeg, gif,
  # flatbuffers). Explicitly force-link every systemized library; abseil
  # ships ~90 shared objects, so enumerate them.
  _absl_libs=""
  for _f in "${PREFIX}"/lib/libabsl_*.so; do
    [ -e "$_f" ] && _absl_libs="${_absl_libs} -l$(basename "$_f" .so | sed 's/^lib//')"
  done
  export LDFLAGS="${LDFLAGS} -lrt -Wl,--export-dynamic -Wl,--no-as-needed -lprotobuf -lgrpc -lgrpc++ -lgpr -lsqlite3 -lpng -ljpeg -lgif -lflatbuffers -licui18n -licuuc -licudata -lsnappy -lcurl -lz -lssl -lcrypto${_absl_libs}"
fi

if [[ ${cuda_compiler_version} != "None" ]]; then
    if [ ${target_platform} == "linux-aarch64" ]; then
	NVARCH=sbsa
    elif [ ${target_platform} == "linux-64" ]; then
	NVARCH=x86_64
    else
	NVARCH=${ARCH}
    fi
    export LDFLAGS="${LDFLAGS} -lcusparse"
    # CUDA device code is compiled by nvcc with clang 18 as the host compiler
    # (TF_NVCC_CLANG). clang 18 itself cannot compile CUDA 13 device code --
    # CUDA 13 removed headers like texture_fetch_functions.h and clang only
    # gained CUDA 13 support in v21 -- so nvcc must handle the .cu files.
    # configure.py reads GCC_HOST_COMPILER_PATH on the TF_CUDA_CLANG=0 path;
    # point it at clang (it only checks the path exists), which is exactly
    # the host compiler nvcc uses under TF_NVCC_CLANG.
    export TF_CUDA_CLANG=0
    export TF_NVCC_CLANG=1
    export TF_NEED_CLANG=1
    export CLANG_CUDA_COMPILER_PATH="${BUILD_PREFIX}/bin/clang"
    export CLANG_COMPILER_PATH="${BUILD_PREFIX}/bin/clang"
    export GCC_HOST_COMPILER_PATH="${BUILD_PREFIX}/bin/clang"
    # nvcc / cicc / ptxas live under nvvm/bin in the conda cuda-nvcc package.
    export PATH="${PATH}:${BUILD_PREFIX}/nvvm/bin"

    export TF_NEED_CUDA=1
    export TF_CUDA_VERSION="${cuda_compiler_version}"
    export TF_CUDNN_VERSION="${cudnn}"
    export HERMETIC_CUDA_VERSION="${cuda_compiler_version}"
    export HERMETIC_CUDNN_VERSION="${cudnn}"
    export TF_NCCL_VERSION=$(pkg-config nccl --modversion | grep -Po '\d+\.\d+')

    export LDFLAGS="${LDFLAGS//-Wl,-z,now/-Wl,-z,lazy}"

    if [[ "${cuda_compiler_version}" == 12* || "${cuda_compiler_version}" == 13* ]]; then
        # clang 18 (the host compiler) only understands compute capabilities
        # up to sm_90; the Blackwell archs sm_100/sm_120 would make clang error
        # ("unsupported CUDA gpu architecture"). Cap the list at sm_90 until a
        # newer clang is in use.
        if [[ "${cuda_compiler_version}" == 13* ]]; then
            # CUDA 13 dropped support for compute capabilities below sm_75
            export HERMETIC_CUDA_COMPUTE_CAPABILITIES=sm_75,sm_80,sm_86,sm_89,sm_90,compute_90
        else
            export HERMETIC_CUDA_COMPUTE_CAPABILITIES=sm_60,sm_70,sm_75,sm_80,sm_86,sm_89,sm_90,compute_90
        fi
        export CUDNN_INSTALL_PATH=$PREFIX
        export NCCL_INSTALL_PATH=$PREFIX
        export CUDA_HOME="${BUILD_PREFIX}/targets/${NVARCH}-linux"
        export TF_CUDA_PATHS="${BUILD_PREFIX}/targets/${NVARCH}-linux,${PREFIX}/targets/${NVARCH}-linux"
        # XLA can only cope with a single cuda header include directory, merge both
        rsync -a ${PREFIX}/targets/${NVARCH}-linux/include/ ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/

        # Although XLA supports a non-hermetic build, it still tries to find headers in the hermetic locations.
        # We do this in the BUILD_PREFIX to not have any impact on the resulting jaxlib package.
        # Otherwise, these copied files would be included in the package.
        rm -rf ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party
        mkdir -p ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party/gpus/cuda/extras/CUPTI
        cp -r ${PREFIX}/targets/${NVARCH}-linux/include ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party/gpus/cuda/
        cp -r ${PREFIX}/targets/${NVARCH}-linux/include ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party/gpus/cuda/extras/CUPTI/
        mkdir -p ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party/gpus/cudnn
        cp ${PREFIX}/include/cudnn*.h ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party/gpus/cudnn/
        mkdir -p ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party/nccl
        cp ${PREFIX}/include/nccl.h ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party/nccl/
        rsync -a ${PREFIX}/targets/${NVARCH}-linux/lib/ ${BUILD_PREFIX}/targets/${NVARCH}-linux/lib/
        mkdir -p ${BUILD_PREFIX}/targets/${NVARCH}-linux/bin
        ln -sf ${BUILD_PREFIX}/bin/fatbinary ${BUILD_PREFIX}/targets/${NVARCH}-linux/bin/fatbinary
        ln -sf ${BUILD_PREFIX}/bin/nvlink ${BUILD_PREFIX}/targets/${NVARCH}-linux/bin/nvlink
        ln -sf ${BUILD_PREFIX}/bin/ptxas ${BUILD_PREFIX}/targets/${NVARCH}-linux/bin/ptxas

        export LOCAL_CUDA_PATH="${BUILD_PREFIX}/targets/${NVARCH}-linux"
        export LOCAL_CUDNN_PATH="${PREFIX}"
        export LOCAL_NCCL_PATH="${PREFIX}"

        # hmaarrfk -- 2023/12/30
        # This logic should be safe to keep in even when the underlying issue is resolved
        # xref: https://github.com/conda-forge/cuda-nvcc-impl-feedstock/issues/9
        if [[ -x ${BUILD_PREFIX}/nvvm/bin/cicc ]]; then
            cp ${BUILD_PREFIX}/nvvm/bin/cicc ${BUILD_PREFIX}/bin/cicc
        fi

        # Needs GCC 13+
        echo "build --define=xnn_enable_avxvnniint8=false" >> .bazelrc

    else
        echo "unsupported cuda version."
        exit 1
    fi
else
    export TF_NEED_CUDA=0
fi

gen-bazel-toolchain

if [[ "${target_platform}" == "osx-64" ]]; then
  # Must match the cpu key gen-bazel-toolchain bakes into bazel_toolchain's
  # cc_toolchain_suite (darwin_x86_64); a bare "darwin" leaves the suite
  # lookup unresolved once TF 2.21.0's apple-toolchain points crosstool_top
  # at it, failing analysis with "does not contain a toolchain for cpu".
  TARGET_CPU=darwin_x86_64
  # See https://conda-forge.org/docs/maintainer/knowledge_base.html#newer-c-features-with-old-sdk
  export CXXFLAGS="${CXXFLAGS} -D_LIBCPP_DISABLE_AVAILABILITY"
elif [[ "${target_platform}" == "linux-aarch64" ]]; then
  TARGET_CPU=aarch64
elif [[ "${target_platform}" == "linux-x86_64" ]]; then
  TARGET_CPU=x86_64
fi

# --cpu key for the crosstool's cc_toolchain_suite lookup. The conda
# //bazel_toolchain suite is keyed by ${TARGET_CPU}; TF's CUDA crosstool
# (@local_config_cuda//crosstool) suite is keyed k8/aarch64, so the CUDA
# build needs k8 on linux-64.
CC_CPU=${TARGET_CPU}
if [[ "${cuda_compiler_version}" != "None" && "${target_platform}" == "linux-64" ]]; then
  CC_CPU=k8
fi

# build.sh invokes build_common.sh repeatedly (once per Python version, and
# twice per version). The work tree -- including .bazelrc -- persists across
# those invocations, so restore .bazelrc to its pristine upstream state before
# editing/appending below. Otherwise the appended config (--cxxopt, --copt,
# --crosstool_top, ...) accumulates duplicate flags, which changes every
# compile command string and defeats all of Bazel's action caching, forcing a
# full ~22k-action recompile on every single invocation.
if [[ ! -f .bazelrc.conda-orig ]]; then
  cp .bazelrc .bazelrc.conda-orig
else
  cp .bazelrc.conda-orig .bazelrc
fi

# Get rid of unwanted defaults
sed -i -e "/PROTOBUF_INCLUDE_PATH/c\ " .bazelrc
sed -i -e "/PREFIX/c\ " .bazelrc
# TF 2.21.0 defaults to the "pywrap" build, which produces a single mega
# library instead of the standalone libtensorflow / libtensorflow_cc shared
# objects that the libtensorflow and libtensorflow_cc packages ship.
# The flag is read as bool(os.environ.get("USE_PYWRAP_RULES", False)), so the
# repo_env entry must be removed entirely -- setting it to "False" (a non-empty
# string) still evaluates truthy.
sed -i -e "/USE_PYWRAP_RULES/d" .bazelrc
# TF's .bazelrc hardcodes -fuse-ld=lld for some configs, but conda's clang
# ships no lld; drop it so the default linker is used.
sed -i -e "/fuse-ld=lld/d" .bazelrc
# Ensure .bazelrc ends in a newline
echo "" >> .bazelrc

if [[ "${target_platform}" == osx-* ]]; then
  # TF 2.21.0's common:apple-toolchain config forces Bazel's Apple Xcode
  # crosstool (@local_config_apple_cc) for the target, host and apple
  # crosstool slots. That bypasses the conda //bazel_toolchain (and its
  # -isystem $PREFIX/include), so conda's protobuf/abseil headers are not
  # found and the [for tool] proto compiles fail. Redirect that config at
  # the conda toolchain instead.
  sed -i 's#@local_config_apple_cc//:toolchain#//bazel_toolchain:toolchain#g' .bazelrc
  # TF 2.21.0's cc_shared_library does not propagate the systemlib protobuf
  # linkopt, so libtensorflow_framework.dylib is linked with no -lprotobuf.
  # -undefined dynamic_lookup hides the resulting undefined protobuf symbols
  # but cannot reconcile the TLS storage class of ThreadSafeArena::
  # thread_cache_ -- ld rejects a thread-local reference to it as a regular
  # (undefined) symbol. Force-link conda's libprotobuf for the target and
  # exec (host) configs so thread_cache_ resolves to its TLS definition.
  cat >> .bazelrc <<EOF
build --linkopt=-L${PREFIX}/lib --linkopt=-lprotobuf
build --host_linkopt=-L${PREFIX}/lib --host_linkopt=-lprotobuf
EOF
fi

if [[ "${target_platform}" == "osx-arm64" ]]; then
  echo "build --config=macos_arm64" >> .bazelrc
  # See https://conda-forge.org/docs/maintainer/knowledge_base.html#newer-c-features-with-old-sdk
  export CXXFLAGS="${CXXFLAGS} -D_LIBCPP_DISABLE_AVAILABILITY"
fi
export TF_ENABLE_XLA=1
export BUILD_TARGET="//tensorflow/tools/pip_package:wheel //tensorflow/tools/lib_package:libtensorflow //tensorflow:libtensorflow_cc${SHLIB_EXT}"

# Python settings
export PYTHON_BIN_PATH=${PYTHON}
export PYTHON_LIB_PATH=${SP_DIR}
export USE_DEFAULT_PYTHON_LIB_PATH=1

# additional settings
export TF_NEED_OPENCL=0
export TF_NEED_OPENCL_SYCL=0
export TF_NEED_COMPUTECPP=0
# CUDA variants set TF_CUDA_CLANG=1 above; only force 0 for the non-CUDA build.
if [[ "${cuda_compiler_version}" == "None" ]]; then
  export TF_CUDA_CLANG=0
fi
if [[ "${target_platform}" == linux-* && "${cuda_compiler_version}" == "None" ]]; then
  export TF_NEED_CLANG=0
fi
export TF_NEED_TENSORRT=0
export TF_NEED_ROCM=0
export TF_NEED_MPI=0
export TF_DOWNLOAD_CLANG=0
export TF_SET_ANDROID_WORKSPACE=0
export TF_CONFIGURE_IOS=0


#bazel clean --expunge
#bazel shutdown

./configure

# Remove legacy flags set by configure that conflicts with CUDA 12+'s multi-directory approach.
if [[ "${cuda_compiler_version}" == 12* || "${cuda_compiler_version}" == 13* ]]; then
    sed -i '/CUDA_TOOLKIT_PATH/d' .tf_configure.bazelrc
fi

if [[ "${build_platform}" == linux-* ]]; then
  $RECIPE_DIR/add_py_toolchain.sh
fi

cat >> .bazelrc <<EOF
# TF 2.21.0 defaults to a hermetic LLVM CC toolchain (rules_ml_toolchain);
# the clang_local config disables it so the conda-forge compiler toolchain
# and system headers are used (--crosstool_top is set per-variant below).
build --config=clang_local
build --@local_config_cuda//cuda:override_include_cuda_libs=true
build --logging=6
build --verbose_failures
build --define=PREFIX=${PREFIX}
build --define=PROTOBUF_INCLUDE_PATH=${PREFIX}/include
build --cpu=${CC_CPU}
build --local_cpu_resources=${CPU_COUNT}
# Persistent on-disk action cache. Survives the rattler-build output tree being
# wiped, so the four per-Python passes here -- and subsequent builds of other
# variants (e.g. CUDA) on the same machine -- reuse already-compiled artifacts
# instead of recompiling from scratch. Content-addressed, so always safe; on a
# fresh CI container /tmp is empty and this is simply a no-op.
build --disk_cache=/tmp/tf-bazel-disk-cache
EOF

# Per-variant crosstool. The CPU build uses the conda gen-bazel-toolchain
# crosstool directly. The CUDA build must route through TF's CUDA crosstool
# instead: its host_compiler is the nvcc wrapper
# (crosstool_wrapper_driver_is_not_gcc), which dispatches per action -- '-x
# cuda' device files (.cu.cc from cuda_library) go to nvcc 13, everything
# else to conda clang 18 (CLANG_CUDA_COMPILER_PATH). A blanket
# --crosstool_top=//bazel_toolchain would force plain clang onto the device
# files and fail on the nvcc-only copts. Mirrors TF's own config:rocm.
if [[ "${cuda_compiler_version}" == "None" ]]; then
  cat >> .bazelrc <<EOF
build --crosstool_top=//bazel_toolchain:toolchain
EOF
else
  # TF's CUDA crosstool (generated by cuda_configure.bzl) carries none of the
  # conda gen-bazel-toolchain customizations. Conda's header dir cannot be
  # injected with --copt=-isystem: Bazel rejects an absolute include path that
  # the toolchain does not declare ("references a path outside ..."). Instead
  # feed it through CPATH -- clang reports CPATH dirs via `clang -E -v`, so
  # cuda_configure.bzl picks $PREFIX/include up into cxx_builtin_include_dirs
  # (declared, hence accepted), and clang also searches CPATH at compile time.
  export CPATH="${PREFIX}/include${CPATH:+:${CPATH}}"
  export CPLUS_INCLUDE_PATH="${PREFIX}/include${CPLUS_INCLUDE_PATH:+:${CPLUS_INCLUDE_PATH}}"
  cat >> .bazelrc <<EOF
build --crosstool_top=@local_config_cuda//crosstool:toolchain
build --host_crosstool_top=@local_config_cuda//crosstool:toolchain
build --action_env=CPATH=${PREFIX}/include
build --host_action_env=CPATH=${PREFIX}/include
build --action_env=CPLUS_INCLUDE_PATH=${PREFIX}/include
build --host_action_env=CPLUS_INCLUDE_PATH=${PREFIX}/include
build --linkopt=-L${PREFIX}/lib --host_linkopt=-L${PREFIX}/lib
EOF
  # Re-supply the force-linked systemlibs (linkopts are not path-validated).
  for _ldflag in ${LDFLAGS}; do
    echo "build --linkopt=${_ldflag}" >> .bazelrc
    echo "build --host_linkopt=${_ldflag}" >> .bazelrc
  done
fi

# conda-forge's linux libabseil/libprotobuf/... use the GCC-compatible
# (pre-clang-18) Itanium mangling for non-type template parameters of
# dependent type. clang 18 changed that mangling, so TF references e.g.
# absl::Cord's enable_if-constrained constructor under a name the conda
# libraries do not export. Pin clang to the GCC-compatible ABI to match.
# Only when actually building with clang: macOS uses Apple clang (which
# rejects this flag value) and the CUDA variants build with gcc (which has
# no -fclang-abi-compat flag at all). Both would error on it.
if [[ "${target_platform}" == linux-* && "${c_compiler}" == clang* ]]; then
  cat >> .bazelrc <<EOF
build --cxxopt=-fclang-abi-compat=17
build --host_cxxopt=-fclang-abi-compat=17
EOF
fi

# CUDA device code is compiled by nvcc (clang 18 cannot target CUDA 13);
# clang remains the host compiler (TF_NVCC_CLANG, set by this config).
if [[ "${cuda_compiler_version}" != "None" ]]; then
  cat >> .bazelrc <<EOF
build --config=cuda_nvcc
EOF
fi

# Update TF lite schema with latest flatbuffers version
pushd tensorflow/compiler/mlir/lite/schema
flatc --cpp --gen-object-api schema.fbs
popd
rm -f tensorflow/lite/schema/conversion_metadata_generated.h
rm -f tensorflow/lite/experimental/acceleration/configuration/configuration_generated.h
rm -f tensorflow/lite/acceleration/configuration/configuration_generated.h
sed -ie "s;BUILD_PREFIX;${BUILD_PREFIX};g" tensorflow/tools/pip_package/build_pip_package.py

# build using bazel
bazel ${BAZEL_OPTS} build ${BUILD_TARGET}

# copy the whl file. Bazel marks its outputs read-only, so a plain cp of an
# already-copied wheel fails; -f removes the stale destination and retries.
mkdir -p $SRC_DIR/tensorflow_pkg
cp -f bazel-bin/tensorflow/tools/pip_package/wheel_house/tensorflow*-cp${PY_VER/./}-*.whl $SRC_DIR/tensorflow_pkg/ || true

if [[ ! -f "${SRC_DIR}/libtensorflow_built" ]]; then
  # Build libtensorflow(_cc)
  mkdir -p ${PREFIX}/lib
  mkdir -p ${PREFIX}/include
  tar -C ${PREFIX} -xzf $SRC_DIR/bazel-bin/tensorflow/tools/lib_package/libtensorflow.tar.gz
  ls -alh ${PREFIX}/lib
  ls -alh ${PREFIX}/include
  cp -RP bazel-bin/tensorflow/libtensorflow_cc.* ${PREFIX}/lib/
  if [[ "${target_platform}" == osx-* ]]; then
    ln -sf ${PREFIX}/lib/libtensorflow_framework.2.dylib ${PREFIX}/lib/libtensorflow_framework.dylib
  fi
  # Make writable so patchelf can do its magic
  chmod u+w ${PREFIX}/lib/libtensorflow*

  mkdir -p ${PREFIX}/include/tensorflow
  rsync -r --chmod=D777,F666 --exclude '_solib*' --exclude '_virtual_includes/' --exclude 'pip_package/' --exclude 'lib_package/' --include '*/' --include '*.h' --include '*.inc' --exclude '*' bazel-bin/ ${PREFIX}/include
  rsync -r --chmod=D777,F666 --include '*/' --include '*.h' --include '*.inc' --exclude '*' tensorflow/cc ${PREFIX}/include/tensorflow/
  rsync -r --chmod=D777,F666 --include '*/' --include '*.h' --include '*.inc' --exclude '*' tensorflow/core ${PREFIX}/include/tensorflow/
  rsync -r --chmod=D777,F666 --include '*/' --include '*.h' --include '*.inc' --exclude '*' third_party/xla/third_party/tsl/ ${PREFIX}/include/
  rsync -r --chmod=D777,F666 --include '*/' --include '*' --exclude '*.cc' third_party/ ${PREFIX}/include/tensorflow/third_party/
  rsync -r --chmod=D777,F666 --include '*/' --include '*' --exclude '*.txt' bazel-work/external/eigen_archive/Eigen/ ${PREFIX}/include/tensorflow/third_party/Eigen/
  rsync -r --chmod=D777,F666 --include '*/' --include '*' --exclude '*.txt' bazel-work/external/eigen_archive/unsupported/ ${PREFIX}/include/tensorflow/third_party/unsupported/
  # Flatten XLA headers from nested external path to top-level include/xla/.
  # TF 2.21.0 renamed the XLA bazel repo @local_xla -> @xla.
  rsync -av "${PREFIX}/include/external/xla/xla/" "${PREFIX}/include/xla/"
  touch "${SRC_DIR}/libtensorflow_built"
fi

# This was only needed for protobuf_python
rm -rf $PREFIX/include/python
