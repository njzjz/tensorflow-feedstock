# In rattler-build each output has its own SRC_DIR; artifacts are shared via /tmp/tf_artifacts.
TF_ARTIFACTS="${SRC_DIR}"
[ -f /tmp/tf_artifacts/libtensorflow_cc_output.tar ] && TF_ARTIFACTS=/tmp/tf_artifacts
tar -C ${PREFIX} -xf $TF_ARTIFACTS/libtensorflow_cc_output.tar
rsync -av ${PREFIX}/include/external/local_xla/xla/ ${PREFIX}/include/xla
