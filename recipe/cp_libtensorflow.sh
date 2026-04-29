# https://github.com/tensorflow/tensorflow/blob/master/tensorflow/tools/lib_package/README.md
# In rattler-build each output has its own SRC_DIR; artifacts are shared via /tmp/tf_artifacts.
TF_ARTIFACTS="${SRC_DIR}"
[ -f /tmp/tf_artifacts/libtensorflow.tar.gz ] && TF_ARTIFACTS=/tmp/tf_artifacts
tar -C ${PREFIX} -xzf $TF_ARTIFACTS/libtensorflow.tar.gz

# Make writable so patchelf can do its magic
chmod u+w $PREFIX/lib/libtensorflow*
