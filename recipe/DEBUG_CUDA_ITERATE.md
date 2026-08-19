# Fast-iteration / debug-mode build for the CUDA TensorFlow builds

Goal: stop paying the ~3 h full rebuild on every CUDA compile fix. Build
once to the failure point, then on each fix re-run only `bazel build` and let
Bazel's incremental cache recompile just what changed (minutes).

Variant configs (pick one per debug session via the `CONFIG` env var):

- `linux_64_cuda_compiler_version13.0microarch_level3` — CUDA 13.0
- `linux_64_cuda_compiler_version12.9microarch_level3` — CUDA 12.9

`iterate.sh` reads `CONFIG` (`CONFIG=${CONFIG:-<13.0 default>}`); export it
before running setup to debug the 12.9 variant. Both variants share the one
host Bazel disk cache, so non-CUDA actions (LLVM, MLIR, protobuf, CPU code) are
reused across them — the second variant builds much faster.

> Status (2026-05-18): both CUDA 13.0 and 12.9 have been built green through
> this loop. Fixes it produced: patches 0067–0070, plus the `libcuda.so.1`
> stub handling in `build_common.sh` / `build.sh`.

---

## 1. How "debug mode" actually works for this feedstock

`build-locally.py --debug` sets `BUILD_WITH_CONDA_DEBUG=1` (build-locally.py
lines 22-25). That env var is forwarded into the container by
`run_docker_build.sh` (`-e BUILD_WITH_CONDA_DEBUG`). But `build_steps.sh` then
does:

```sh
if [[ "${BUILD_WITH_CONDA_DEBUG:-0}" == 1 ]]; then
    echo "rattler-build currently doesn't support debug mode"
else
    rattler-build build --recipe ...
fi
```

So `build-locally.py --debug` is a **dead end for this feedstock** — it just
prints that message and does nothing. The feedstock scaffolding pre-dates
rattler-build's debug support.

**However**, the rattler-build actually installed in the container
(`rattler-build 0.64.1`, found at `/opt/conda/bin/rattler-build`) *does* have a
full `debug` subcommand. We use it directly instead of going through
`build_steps.sh`.

`rattler-build debug --help` subcommands:

```
setup         Set up a debug environment from a recipe
shell         Open an interactive debug shell in an existing build environment
host-add      Install additional packages into the host prefix
build-add     Install additional packages into the build prefix
workdir       Print the work directory path
run           Re-run the build script in an existing debug environment
create-patch  Create a patch from changes in the work directory
```

`rattler-build debug setup --help` says exactly what we want:

> Set up a debug environment from a recipe.
> Resolves dependencies, downloads sources, applies patches, installs
> build/host environments, and creates the build script — then stops.
> Use `debug shell` or `debug run` afterwards to work in the environment.

`rattler-build debug shell` (drops you into the work dir with `build_env.sh`
sourced) and `rattler-build debug run` (re-runs `conda_build.sh`) are the
iterate primitives. `debug create-patch` turns work-dir edits into a patch
file in the recipe dir for the `patches:` list.

The full subcommand behaviour, verified in the container (rattler-build 0.64.1):

- `debug setup`  — resolves deps, downloads + extracts the TF tarball, applies
  all recipe `patches:`, installs the build and host conda envs, writes
  `build_env.sh` + `conda_build.sh`, then **stops**. Requires `--output-name`
  because the recipe is multi-output.
- `debug run`    — sources `build_env.sh` and executes `conda_build.sh` (the
  recipe `build.sh`). `--trace` for `bash -x`. `--work-dir` to pick a workdir;
  otherwise read from `./output/rattler-build-log.txt`.
- `debug shell`  — interactive shell with `build_env.sh` sourced, cwd = workdir.
- `debug workdir`— prints the work dir path. With no `--work-dir` it reads the
  **last** entry of `./output/rattler-build-log.txt` *relative to the current
  directory* — so it must be run from `/home/conda` (the dir that contains
  `output/`), else it errors `rattler-build-log.txt not found`.
- `debug build-add` / `debug host-add` — install extra packages into the
  build / host prefix without re-running `debug setup`.
- `debug create-patch` — unified diff of work-dir edits, written into the
  recipe dir for the `patches:` list.

The debug env layout (verified) — under
`/home/conda/output/bld/rattler-build_tensorflow-build_<id>/`:

- `work/`        — patched TF source; `$SRC_DIR` and `$HOME` both point here
- `work/build_env.sh`   — exports `PREFIX`, `BUILD_PREFIX`, `RECIPE_DIR`, etc.
- `work/conda_build.sh` — sources `build_env.sh` then runs the recipe `build.sh`
- `work/.source_info.json` — records recipe path + applied patches
- `build_env/`   — `$BUILD_PREFIX` (compilers, cuda-nvcc, bazel, ...)
- `host_env_placehold.../` — `$PREFIX` (host deps: cudnn, protobuf, abseil, ...)
- `/home/conda/output/rattler-build-log.txt` — JSON line per debug build,
  records `work_dir` / `build_prefix` / `host_prefix` / `recipe_dir`.

`RECIPE_DIR=/home/conda/recipe_root` — i.e. the mounted `recipe/` directory, so
editing `recipe/build_common.sh` on the host is immediately visible inside.

The persistent work dir + a Bazel `output_base` inside `work/.cache/bazel`
survive across `debug run` / `bazel build` invocations **as long as the
container stays alive**, so Bazel rebuilds incrementally — exactly the loop
we want.

---

## 1a. REQUIRED temporary recipe edit (must be reverted before any commit)

`rattler-build debug` only enumerates the recipe's `package:` outputs. The
heavy Bazel build lives in a **`staging:` output** named `tensorflow-build`, so
`debug setup --output-name tensorflow-build` fails with
`Output with name 'tensorflow-build' not found`.

To debug it, `recipe/recipe.yaml` must be **temporarily** edited:

1. Convert the staging output into a real package output:

   ```yaml
   # ORIGINAL:
     - staging:
         name: tensorflow-build
   # TEMP EDIT:
     - package:
         name: tensorflow-build
         version: ${{ version }}
   ```

2. Comment out the ~10 trailing `package:` outputs that `inherit:
   tensorflow-build` (recipe.yaml lines ~218–559, every output from
   `libtensorflow_framework` down to `tensorflow-avx512`). They must be removed
   because `inherit:` requires a *staging* cache by that name, which no longer
   exists once the conversion above is made. Each non-blank line gets a
   `# DEBUG-TEMP ` prefix.

After this edit `outputs:` contains exactly one output (`tensorflow-build`) and
`debug setup --output-name tensorflow-build` succeeds.

**THIS EDIT IS TEMPORARY AND MUST NOT BE COMMITTED.** Revert it with:

```sh
git checkout recipe/recipe.yaml
```

before any `git commit` / `git push`. `iterate.sh` has `recipe-debug` /
`recipe-revert` helpers that apply and revert this edit.

### Container lifetime

A normal `build-locally.py` run starts a container that **exits when the build
finishes/fails** (the container is not `--rm` by default but it stops). For
iteration we deliberately start the container with a **long-lived command**
(`sleep infinity`) so it stays up across many `bazel build` invocations, and we
re-enter it with `docker exec`.

---

## 2. Persistent Bazel cache across runs (the big win)

`recipe/build_common.sh` already appends `build --disk_cache=/tmp/tf-bazel-disk-cache`
to `.bazelrc`. The disk cache is content-addressed, so it is always safe to
share. The problem: inside the container `/tmp` is the container's overlay
filesystem — ephemeral, gone the moment the container is removed. (`mount`
inside the container shows `/tmp` is not a separate volume.)

Fix: **bind-mount a host directory onto `/tmp/tf-bazel-disk-cache`.**
`run_docker_build.sh` honors `CONDA_FORGE_DOCKER_RUN_ARGS`:

```sh
DOCKER_RUN_ARGS="${CONDA_FORGE_DOCKER_RUN_ARGS}"
```

Host cache directory (already created by this prep):

```
/MCAM_data/tf-bazel-disk-cache
```

(The cache lives on `/MCAM_data` — 2.3 TB free — deliberately off the
space-constrained `/home`. A full CUDA TF build's disk cache is ~25–30 GB.)

Exact value to export before `build-locally.py` (or any `docker run`):

```sh
export CONDA_FORGE_DOCKER_RUN_ARGS="-v /MCAM_data/tf-bazel-disk-cache:/tmp/tf-bazel-disk-cache"
```

With that mount, a fresh container — even a brand-new `build-locally.py` run —
reuses every compiled action from the previous run. Combined with the
`output_base` note below, an incremental rebuild after a one-file fix is
minutes, not hours.

Note on `output_base`: Bazel's `output_base` lives under `$HOME/.cache/bazel`
and `$HOME` = the per-run `work/` dir, so `output_base` is *not* itself
persistent. That is fine: the `--disk_cache` is what carries compiled actions
across runs. If you keep the **same container alive** (recommended, see below)
and just re-run `bazel build` in the same `work/` dir, then `output_base` is
also preserved and the rebuild is incremental in the strongest sense (no cache
re-fetch at all).

---

## 3. The interactive iterate loop

Two ways to drive it. The persistent-container way is fastest.

### One-time setup (run once)

```sh
# On the host, in the feedstock root:
cd /home/mark/git/feedstocks/tensorflow-feedstock

export CONFIG=linux_64_cuda_compiler_version13.0microarch_level3
export DOCKER_IMAGE=quay.io/condaforge/linux-anvil-x86_64:alma9
mkdir -p /MCAM_data/tf-bazel-disk-cache

# Start a long-lived container with the feedstock + persistent bazel cache
# mounted. Mirrors the volumes run_docker_build.sh uses.
docker run -d --name tf-cuda-debug \
  -v /home/mark/git/feedstocks/tensorflow-feedstock:/home/conda/feedstock_root:rw,z,delegated \
  -v /home/mark/git/feedstocks/tensorflow-feedstock/recipe:/home/conda/recipe_root:rw,z,delegated \
  -v /MCAM_data/tf-bazel-disk-cache:/tmp/tf-bazel-disk-cache:rw,z \
  -e CONFIG=$CONFIG \
  "$DOCKER_IMAGE" sleep infinity

# Apply the TEMPORARY recipe edit from section 1a (staging -> package +
# comment out inheriting outputs) so debug setup can target tensorflow-build:
./iterate.sh recipe-debug      # or edit recipe/recipe.yaml by hand

# Set up the debug environment: solves deps, installs build+host envs,
# extracts TF source, applies all recipe patches, writes build_env.sh /
# conda_build.sh -- then STOPS. Run from /home/conda so the resulting
# rattler-build-log.txt lands at /home/conda/output/rattler-build-log.txt.
docker exec -w /home/conda tf-cuda-debug \
  /opt/conda/bin/rattler-build debug setup \
    --recipe /home/conda/recipe_root \
    --variant-config /home/conda/feedstock_root/.ci_support/$CONFIG.yaml \
    --target-platform linux-64 \
    --output-name tensorflow-build
```

`--output-name tensorflow-build` selects the (temporarily un-staged) output
whose script is `build.sh` — the actual bazel build.

Verified result: work dir
`/home/conda/output/bld/rattler-build_tensorflow-build_<id>/work` with the TF
source extracted, all recipe patches applied, build + host conda envs installed,
and `build_env.sh` / `conda_build.sh` written.

### Build to the failure point

The recipe's `build.sh` loops over Python 3.10/3.11/3.12/3.13 and runs
`build_common.sh` twice each, then `bazel clean`. For *iteration* you do NOT
want that loop or the final `bazel clean`. Drive `build_common.sh` directly for
a single Python version:

```sh
docker exec -it -w /home/conda tf-cuda-debug bash -lc '
  WORK=$(/opt/conda/bin/rattler-build debug workdir)   # run from /home/conda
  cd "$WORK"
  source build_env.sh          # exports PREFIX, BUILD_PREFIX, RECIPE_DIR, ...
  export PY_VER=3.12           # pick one version to iterate on
  bash $RECIPE_DIR/build_common.sh
'
```

`build_common.sh` is what assembles `.bazelrc` and the bazel flags and ends
with the `bazel ... build ...` line — so running it reproduces the exact failing
compile. It already restores `.bazelrc` from `.bazelrc.conda-orig` at the top of
every run, so re-running it is idempotent and does not corrupt the cache.

### Iterate (the fast loop — minutes per cycle)

When a compile fails:

1. Read the error.
2. Edit the fix on the **host**:
   - recipe/toolchain change -> edit `recipe/build_common.sh` (or other
     `recipe/*` files); visible in-container instantly via the mount.
   - TF source change -> edit the file under the work dir
     `/home/conda/output/bld/rattler-build_tensorflow-build_<id>/work/...`
     (inside the container; or via `docker exec` / `docker cp`). The output
     dir lives on the container overlay, not a host mount.
3. Re-run the build inside the **same** container:

   ```sh
   docker exec -it -w /home/conda tf-cuda-debug bash -lc '
     WORK=$(/opt/conda/bin/rattler-build debug workdir)
     cd "$WORK"; source build_env.sh; export PY_VER=3.12
     bash $RECIPE_DIR/build_common.sh
   '
   ```

   Bazel reuses `output_base` (same container) AND `--disk_cache` (host mount),
   so only actions whose inputs/flags changed recompile. Most fixes touch one
   header or one flag -> minutes.

   To skip `build_common.sh`'s `.bazelrc` regeneration entirely (when the fix
   is purely a TF source edit, not a flag change), just re-run the bazel line:

   ```sh
   docker exec -it -w /home/conda tf-cuda-debug bash -lc '
     WORK=$(/opt/conda/bin/rattler-build debug workdir)
     cd "$WORK"; source build_env.sh
     bazel build //tensorflow/tools/pip_package:wheel \
                 //tensorflow/tools/lib_package:libtensorflow \
                 //tensorflow:libtensorflow_cc.so
   '
   ```

4. Repeat until the build succeeds.

### Capturing a fix as a patch — git-track the work dir (recommended)

The work dir holds the TF source with all recipe `patches:` already applied.
`git init` it once, right after `debug setup`, so the patched tree is the
baseline; then every source fix becomes a real feedstock patch via
`git format-patch` — proper `From:`/`Subject:` headers, ready to drop into
`recipe/patches/` (the feedstock patch series *is* `git format-patch` output).

One-time, immediately after `debug setup` (the container has git at
`/opt/conda/bin/git`):

```sh
docker exec -w "$WORK" tf-cuda-debug bash -lc '
  export PATH=/opt/conda/bin:$PATH
  git init -q
  git config user.email build@local && git config user.name tf-cuda-debug
  printf "bazel-*\nbazel_output_base/\n.bazelrc\n.bazelrc.conda-orig\n.tf_configure.bazelrc\n" > .gitignore
  git add -A && git commit -q -m "Baseline: TF 2.21.0 + feedstock patches applied"
'
```

After a source fix compiles clean, commit it with the real author and emit
the patch straight into the feedstock:

```sh
docker exec -w "$WORK" tf-cuda-debug bash -lc '
  export PATH=/opt/conda/bin:$PATH
  git add <changed files>
  git -c user.name="Mark Harfouche" -c user.email="mark@…" \
      commit -q -m "<subject>\n\n<body>"
  git format-patch -1 --stdout -- <changed files>
' > recipe/patches/00NN-<desc>.patch
```

Then add the `- patches/00NN-<desc>.patch` line to `recipe.yaml`. Pass the
explicit pathspec to `format-patch` so build artifacts never leak into the
patch. `iterate.sh patch <name>` still wraps `rattler-build debug
create-patch` as an alternative, but the git route gives proper headers and
lets you stack/reorder fixes.

### Re-entering / inspecting

```sh
# A plain shell with the build env, anytime:
docker exec -w /home/conda/feedstock_root tf-cuda-debug \
  /opt/conda/bin/rattler-build debug shell

# Or just exec bash and source build_env.sh yourself.
```

### Tear-down

```sh
docker rm -f tf-cuda-debug
# The host bazel cache /MCAM_data/tf-bazel-disk-cache PERSISTS
# and will accelerate the next debug session or build-locally.py run.

# REVERT the temporary recipe edit before any git commit / push:
git -C /home/mark/git/feedstocks/tensorflow-feedstock checkout recipe/recipe.yaml
# or: ./iterate.sh recipe-revert
```

---

## 4. Using build-locally.py with the persistent cache (alternative)

If you prefer the normal `build-locally.py` path (full rattler-build run, not
the debug subcommand), you still get the cross-run speedup just by exporting the
mount first:

```sh
export CONDA_FORGE_DOCKER_RUN_ARGS="-v /MCAM_data/tf-bazel-disk-cache:/tmp/tf-bazel-disk-cache"
python build-locally.py linux_64_cuda_compiler_version13.0microarch_level3
```

Each run still spins a fresh container and re-solves/re-extracts (a few
minutes of overhead) and loses `output_base`, but every *compiled action* is
served from the host disk cache. This is slower per cycle than the
persistent-container loop above, but requires zero deviation from the standard
workflow. The persistent-container `debug` loop in section 3 is the
recommended fast path.

---

## Summary

- `build-locally.py --debug` does nothing useful here — `build_steps.sh`
  explicitly skips rattler-build when `BUILD_WITH_CONDA_DEBUG=1`.
- The installed `rattler-build 0.64.1` has a real `debug` subcommand
  (`setup` / `shell` / `run` / `workdir` / `create-patch`) that builds the
  envs + extracts + patches the source, then stops — use it directly.
- `debug` only sees `package:` outputs, so the `staging: tensorflow-build`
  output is NOT debuggable as-is. Section 1a's TEMPORARY recipe edit converts
  it to a `package:` output and comments out the inheriting outputs. **That
  edit must be reverted (`git checkout recipe/recipe.yaml`) before any commit.**
- Persistent Bazel cache:
  `export CONDA_FORGE_DOCKER_RUN_ARGS="-v /MCAM_data/tf-bazel-disk-cache:/tmp/tf-bazel-disk-cache"`
  host dir: `/MCAM_data/tf-bazel-disk-cache` (already created).
- Fastest loop: one long-lived `sleep infinity` container, `rattler-build
  debug setup` once, then edit-on-host + re-run `build_common.sh` (or just the
  `bazel build` line) inside the same container — incremental, minutes per fix.
