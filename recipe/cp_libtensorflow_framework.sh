# https://github.com/tensorflow/tensorflow/blob/master/tensorflow/tools/lib_package/README.md
# Extract only the framework library, not the C API (libtensorflow.so)
mkdir -p "${PREFIX}/lib"
if [[ "$target_platform" == "osx-"* ]]; then
    tar -C "${PREFIX}/lib" --strip-components=1 -xzf $SRC_DIR/libtensorflow.tar.gz \
        --wildcards "lib/libtensorflow_framework.*dylib"
else
    tar -C "${PREFIX}/lib" --strip-components=1 -xzf $SRC_DIR/libtensorflow.tar.gz \
        --wildcards "lib/libtensorflow_framework.so*"
fi

# Make writable so patchelf can do its magic
chmod u+w $PREFIX/lib/libtensorflow_framework*
