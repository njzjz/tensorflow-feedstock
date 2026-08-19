# Using Claude Code to move the tensorflow-feedstock forward

This is a field guide, not a tutorial. It distills the hard-won lessons from the
TF 2.21.0 + CUDA 13.0 update — a multi-day grind of ~40 CPU build attempts, a
dozen CUDA attempts, ~16 troubleshooting subagents, several wrong turns, and one
genuine mess (a commit that swept in 1,178 deletions). The `tensorflow-feedstock`
is one of the heaviest builds on conda-forge: a single variant is a ~3-hour Bazel
compile that consumes tens of GB. Treat Claude as a research-and-iterate engine,
not a fire-and-forget builder. Read this before starting a version bump.

The intended reader is the maintainer (Mark Harfouche) and future contributors.
Companion docs: `DEBUG_CUDA_ITERATE.md` (the rattler-build debug loop in detail)
and `~/tf-cuda-debug/iterate.sh` (the helper script).

---

## 1. Long multi-hour builds: the checkpoint pattern

A TF build runs for hours. You cannot block on it, and you cannot trust an agent
to babysit it.

**What does NOT work: a "monitor agent" holding a long `sleep`.** Spawning a
subagent whose job is `sleep 1200` then report status fails — agents return early
and do not reliably hold a 20-minute sleep. This was discovered the hard way
mid-session ("The monitor-agent keeps returning early instead of sleeping —
agents don't reliably hold a 20-min `sleep`"). Do not ask an agent to wait.

**What works: a background shell as a heartbeat.** Launch the build with
`run_in_background`, and use a background shell with an `until`-loop or a single
`sleep N` checkpoint as the timer. The background shell re-invokes Claude when it
exits — that is the reliable progress signal. Each checkpoint runs:

```sh
date "+%Y-%m-%d %H:%M:%S"
docker ps --format '{{.Image}} {{.Status}}'
pgrep -af build-locally.py | grep -v pgrep || echo "no build process"
grep -oE '\[[0-9,]+ / [0-9,]+\]' /tmp/tf-build-logs/<log> | tail -1   # Bazel progress
grep -iE 'error|FAILED' /tmp/tf-build-logs/<log> | tail              # errors
```

Notes from real runs:
- A non-zero exit from the checkpoint is usually just `grep` matching nothing
  ("0 errors") — expected, not a failure.
- Bazel's `[done / total]` action count is the live progress signal. But the
  **total is not comparable across attempts** — a crosstool/config change rebuilds
  the action graph (seen: 24,872 → 38,966 → 10,410 → 46,009). Judge progress by
  *error class shifting*, not by raw numbers.
- The user explicitly wants every status update to state the **current local
  time and the time of the next update**. Do that.

---

## 2. Subagent delegation

Subagents were the single biggest force multiplier in this work. ~16 were spawned.
Patterns that worked:

**Delegate research and log-analysis, keep the build loop in the main thread.**
Good subagent jobs: "analyze this CI failure log", "research how jaxlib does X",
"rebase this patch group", "find the upstream commit that fixes Y". The main
thread keeps the build, the git state, and the decision-making.

**Give the agent the SOLUTION mandate, not just the problem.** The prompts that
produced useful output said "determine the exact `build_common.sh` change" or
"find the CORRECT fix by studying how other feedstocks handle this" — not "look
at this error". Tell the agent to come back with a concrete, applyable fix.

**Hand agents precise inputs.** For CI failures, download the Azure blob log
locally first (`curl` the `productionresultssa*.blob.core.windows.net/...` URL
into `/tmp/<name>.log`) and point the agent at the file with the line count and
the exact job name. Agents fetching huge logs themselves waste turns.

**Parallelize independent agents.** When several CI platforms fail at once,
spawn one agent per platform in a single batch (done: CUDA-13 + osx_64 +
pytorch-cpu-CUDA-policy investigated concurrently). Do not serialize independent
investigations.

**Use a "motivator" agent for morale on long grinds** — the user explicitly asked
for this ("never stop, motivate yourself with an agent"). It is a real
instruction, not a joke.

**Verify agent output before acting.** Agents are confident and sometimes wrong.
The review agent at index 2468 caught that a "hermetic Python" fix was suspect;
the user's own instinct flagged it too. Cross-check an agent's fix against a
sibling feedstock before committing it.

---

## 3. The debug fast-iteration loop (the biggest CUDA win)

Iterating a CUDA fix by re-running `build-locally.py` from scratch is a ~3-hour
cycle. The fast loop builds *once* to the failure point, then re-runs only
`bazel build` in a live container — minutes per fix. Full mechanics are in
`DEBUG_CUDA_ITERATE.md`; the essentials:

- `build-locally.py --debug` is a **dead end here** — `build_steps.sh` explicitly
  skips rattler-build when `BUILD_WITH_CONDA_DEBUG=1`. Use the `rattler-build
  debug` subcommand directly instead (`setup` / `shell` / `run` / `workdir` /
  `create-patch`).
- **The staging-output trap.** The heavy Bazel compile lives in a `staging:`
  output (`tensorflow-build`, the CEP 41 megabuild pattern), and `rattler-build
  debug` only enumerates `package:` outputs. So you must make a **temporary**
  recipe edit: convert `staging:` → `package:` and comment out the ~10 outputs
  that `inherit: tensorflow-build`. `iterate.sh recipe-debug` applies it;
  `iterate.sh recipe-revert` undoes it. **This edit must be reverted
  (`git checkout recipe/recipe.yaml`) before any commit** — it is not part of the
  feedstock.
- Run a **long-lived container** (`sleep infinity`), `debug setup` once, then
  edit-on-host + re-run `build_common.sh` (or just the `bazel build` line) inside
  the same container. Bazel reuses `output_base` (same container) and a
  host-mounted `--disk_cache` — incremental rebuilds.
- Persistent Bazel cache: bind-mount a host dir onto `/tmp/tf-bazel-disk-cache`
  via `export CONDA_FORGE_DOCKER_RUN_ARGS="-v
  /home/mark/tf-cuda-debug/bazel-disk-cache:/tmp/tf-bazel-disk-cache"`. This even
  speeds up plain `build-locally.py` runs.

**Git-track the work directory.** `git init` the extracted TF source in the debug
work dir. Then every fix to TF source becomes a clean `git format-patch` that
drops straight into `recipe/patches/`. `rattler-build debug create-patch` also
produces a patch, but a git history in the work dir lets you build patches one at
a time and keeps the series reviewable.

---

## 4. Patch hygiene

The feedstock carries ~55 patches in `recipe/patches/`. They are load-bearing and
fragile.

- **Preserve original-author attribution.** Many patches are Uwe Korn's. During
  the 2.19.1 → 2.21.0 rebase, regenerated patches got their `From:` line stamped
  with the placeholder `x <x@x.com>`, losing authorship. A dedicated agent had to
  restore it. When you regenerate a patch, carry forward the original `From:` and
  `Date:` lines — do not let `git format-patch` overwrite them with your identity.
- **Rebase against a real TF checkout, one patch at a time.** The rebase was done
  by cloning TF at the target tag, applying patches sequentially on top of the
  pristine tag commit, and committing each. `git reset --hard <tag> && git clean
  -fdx` resets cleanly between attempts. Patches were grouped (absl / protobuf /
  CUDA / misc) and rebased by parallel agents, each in its own checkout.
- **Keep the series in logical order.** Numbered prefixes (`0001-`, `0002-`, …)
  encode apply order. When a patch becomes obsolete (upstream fixed it), drop it
  and note it — do not leave dead patches.
- TF 2.21.0 structural change worth knowing: `third_party/absl|gpus|eigen3|ducc/`
  moved under `third_party/xla/third_party/`; `setup.py` became `setup.py.tpl`.
  Rebasing any path-sensitive patch needs this.

---

## 5. Sibling feedstocks are the source of truth

The recurring failure mode in this session was *hand-crafting* a fix instead of
copying a proven one. Every time the work followed a sibling feedstock it
succeeded; every time it guessed it stumbled.

- **CUDA variant policy → `pytorch-cpu-feedstock`.** Which CUDA versions to build
  vs skip/drop: copy verbatim. The decision to drop CUDA 12.8 and build 12.9 +
  13.0 came straight from there.
- **CUDA + clang wiring → `jaxlib-feedstock`.** jaxlib builds XLA-based code with
  clang and has CUDA variants. The `conda_build_config.yaml` zip-group structure
  that finally made the rerender succeed (see §7) was copied from jaxlib.
- **Migrators (`cuda130.yaml`, etc.) → take verbatim** from the conda-forge
  feedstock PR / `conda-forge-pinning`. `cuda130.yaml` here came verbatim from
  conda-forge tensorflow-feedstock PR #490. Do not write migrators by hand.
- **Skips and selectors → copy.** A hand-written selector caused the worst CPU
  regression of the session (§8).

The user stated this preference directly: *"do whatever pytorch-cpu-feedstock
does"*, *"We can follow Jax instead of being firm"*. When in doubt, find the
sibling and mirror it.

---

## 6. Validate via the canonical path

Two traps here.

**`pixi` / direct `rattler-build` is not the canonical build.** Iterating
directly with `pixi run build-...` is fine for speed, but conda-forge CI runs
`build-locally.py` (the Docker path). They differ. The session deliberately
budgeted a step to "debug what happens with `python build-locally.py`" *before*
trusting the recipe. Always confirm a green build through `build-locally.py`
before declaring a variant done.

**The `--test skip` trap.** Running rattler-build with `--test skip` (or
otherwise skipping the test phase) hides runtime crashes — it skips `import
tensorflow`. A build can package cleanly and still SIGABRT on import. The
protobuf descriptor double-registration crash (§9) only surfaced *in the test
phase*. Do not skip tests when you want to claim a variant works.

---

## 7. conda-forge specifics

- **`conda-smithy rerender`** regenerates `.ci_support/`, `.scripts/`,
  `.github/workflows/`. Run it via `pixi run rerender`. For CUDA variants to
  render you must set `CF_CUDA_ENABLED=True`. After every rerender, check `git
  status` / `git show --stat` (see §8).
- **The `unix` zip-group length trap.** conda-forge compiler keys (`c_compiler`,
  `cxx_compiler`, `c_stdlib_version`, …) form one **zip group**; under
  `CF_CUDA_ENABLED` it is length-2 (CPU entry + CUDA entry). A single-entry
  override of one key desyncs the group and the rerender fails with `ValueError`.
  The fix (copied from jaxlib): give every overridden key **two parallel
  entries**, plus the matching `c_stdlib_version` block. This is exactly what
  finally got clang 18 onto the CPU and CUDA-12.9 variants.
- **Migrations live in `.ci_support/migrations/`** (`cuda129.yaml`,
  `cuda130.yaml`, `icu78.yaml`, `absl_grpc_proto_26Q1.yaml`). A wrong migrator
  *type* silently changes which variants render — an early attempt used the wrong
  type and the rerender dropped all CPU (`None`) variants. The official cuda130
  migrator uses `operation: key_add`.
- The user instructed: rerender *before* spending hours building a variant, in
  case the rerender drops it.

---

## 8. Anti-patterns that wasted real time

These are not hypothetical — each one cost time in this session.

- **A config-time selector that silently dropped clang everywhere.** Commit
  `27f4df6` tried to restrict the clang pin to the CPU variant with a
  `cuda_compiler_version == "None"` selector in `conda_build_config.yaml`. That
  selector cannot evaluate at config-parse time, so clang was dropped from
  *every* variant — the CPU build fell back to gcc and XLA's `-emit-llvm` codegen
  broke. Lesson: `conda_build_config.yaml` selectors are not general-purpose
  conditionals; do not gate compilers with them. Copy the zip-group approach (§7).
- **A commit that swept in 1,178 deletions.** A failed `conda-smithy rerender`
  left file *deletions* staged (`.scripts/`, `.github/workflows/conda-build.yml`,
  variant files). The next commit (`0bc3bdb`) `git add`-ed everything and swept
  them all in. Recovery was a hard reset to before that commit and re-applying
  only the good edits. Lesson: **after any rerender, run `git show --stat` /
  `git status` and look for unexpected deletions before committing.** Never blind
  `git add -A` after a rerender.
- **`-DPROTOBUF_NO_THREADLOCAL` on osx.** Commit `9c805b1` defined this macro to
  fix a TLS link error; protobuf's `port_def.inc` *explicitly forbids* externally
  defining it. Reverted in `282d5dc`. Lesson: when a header guards against a
  macro, that is the answer — do not define it anyway.
- **Papering over a real bug.** A `cp -rn python3.*` hack to supply Python
  headers was version-mismatched and `cp -rn` will not even replace a missing
  file. The review agent flagged it. Lesson: make the real failure fatal and
  fix it, do not paper over it.
- **`pkill` catching the wrong process.** A `pkill` aimed at one process killed
  the status-monitor shell too. Scope `pkill`/`pgrep` patterns tightly.
- **Stale `output/bld` dirs not cleaning.** `rm -rf output/bld` silently failed
  because Bazel marks its install tree read-only — 40 stale dirs accumulated. Use
  `chmod -R u+w` before `rm`, or `find ... -delete` with permission fixes.
- **Force-linking / symlinking CUDA driver+stub libs (a long rabbit hole).** We
  added `-lnvidia-ml`/`-lcusparse` to `LDFLAGS` and symlinked `libcuda.so.1`/
  `libnvidia-ml.so.1` stubs into `$PREFIX/lib` to satisfy build-time tools. But
  under `--config=cuda_wheel` (`include_cuda_libs=false`) XLA already routes
  every CUDA lib through its in-tree lazy-dlopen stubs (`//xla/tsl/cuda:{cuda,
  nvml,cusparse,...}`), so the `.so`s should have *no* `DT_NEEDED` for them.
  Force-linking via `LDFLAGS` leaks an unconditional `NEED` into every output
  (Bazel reorders linkopts and strips any `--as-needed` scope), and NVML ships
  only with the driver, so `import tensorflow` then fails in the conda test env.
  Lesson: never put CUDA libs in `LDFLAGS` or symlink their stubs into
  `$PREFIX/lib`; if a target genuinely references a CUDA symbol, add the matching
  `//xla/tsl/cuda:<lib>` stub to its BUILD deps (patch 0074).

---

## 9. Toolchain pitfalls encountered (CPU and CUDA)

Concrete error → fix pairs from this build. Expect these to recur on the next bump.

| Symptom | Root cause | Fix |
|---|---|---|
| `no such target '@@com_google_absl//absl/...'` in Bazel analysis | TF 2.21.0 dropped `system_build_file`/`system_link_files` from absl's `workspace.bzl`; systemlib BUILD overlays missing targets | Patch 0050 restores absl systemlib wiring; add every referenced absl target to the overlay BUILD files |
| `cc_proto_library` / `py_proto_library` rejected | TF 2.21.0 + vendored deps (riegeli) call proto rules with the *modern* `deps=[proto_library]` convention; old systemlib shims use the legacy convention | Patch 0052 supplies modern proto-rule shims (`@com_google_protobuf//bazel:*.bzl`) |
| `framework.so` missing `DT_NEEDED` for system absl/snappy/curl | TF 2.21.0's `cc_shared_library` does not forward systemlib `cc_library` linkopts | `build_common.sh` force-links via `LDFLAGS` (`-Wl,--no-as-needed` + every `$PREFIX/lib/libabsl_*.so`). Over-links — revisit if upstream fixes it |
| `absl::Cord` ctor undefined at link | clang 18 changed Itanium mangling of non-type template params of dependent type vs the pre-18 GCC-compatible form that conda-forge libabseil/libprotobuf export | `build_common.sh` adds `--cxxopt/--host_cxxopt=-fclang-abi-compat=17`. **Linux only** — Apple clang rejects the flag (`d3a2080`); gate it to clang builds (`a2de779`) |
| osx: conda protobuf/absl headers vanish on `[for tool]` proto compiles | TF 2.21.0's `.bazelrc` has `common:macos --config=apple-toolchain`, forcing the Apple Xcode crosstool into all three crosstool slots, bypassing the conda `//bazel_toolchain` | `sed` the apple-toolchain config to point at the conda toolchain (`5763de8`) |
| CUDA: `./configure` fails — `Invalid GCC_HOST_COMPILER_PATH` | Building CUDA with clang needs the CUDA-clang config, not gcc | `TF_CUDA_CLANG=1`, then `TF_NVCC_CLANG=1` + `--config=cuda_nvcc` (`f44570f`, `479fba1`) |
| clang 18 cannot do CUDA 13 device code; gets `-Xcuda-fatbinary`, `sm_100`/`sm_120` | clang 18 predates Blackwell + CUDA 13 | Use **nvcc for device code, clang 18 as host**; cap compute caps at `sm_90` (`f3482a5`); add `-Qunused-arguments` (`4362a0b`) |
| CUDA: conda headers/libs missing (`sqlite3ext.h`, `absl/...`) | Routing through TF's CUDA crosstool drops the conda toolchain's baked-in `-isystem $PREFIX/include` | Re-supply conda include/lib via `CPATH` and crosstool config (`e342b9b`, `1a298d2`) |
| CUDA: `'cub/iterator/counting_input_iterator.cuh' file not found` | CUDA 13.0 bundles **CCCL/CUB 3.0.1**, which removed/relocated APIs TF 2.21.0's `gpu_prim.h` uses (`CountingInputIterator`, `TransformInputIterator`, `NumericTraits`, `Int2Type`, …) | Backport upstream commit `ff3bc75` *"Make tensorflow buildable with CCCL v3.x"*; flatten CUDA 13 cccl headers so `cub/`/`thrust/` resolve (`556f356`) |
| `import tensorflow` SIGABRT — `File already exists in database: ...exported_model.proto` | protobuf descriptor double-registration: a proto compiled into two libraries | Ensure protobuf is consistently systemized vs vendored; see commits `67000d4`/`b689f1c` on `tf_proto_library` dep chains |
| `import tensorflow`: `libnvidia-ml.so.1: cannot open shared object file` | `-lnvidia-ml`/`-lcusparse` in `LDFLAGS` (or a `$PREFIX/lib` stub symlink) baked a hard `DT_NEEDED` into every `.so`; NVML ships only with the driver | Do **not** force-link/symlink CUDA libs — `--config=cuda_wheel` routes them through XLA's lazy-dlopen stubs. If a target needs a CUDA symbol, add `//xla/tsl/cuda:<lib>` to its BUILD deps (patch 0074) |

Cross-cutting toolchain notes:
- **Hermetic CUDA vs conda CUDA.** TF defaults to hermetic CUDA redists. The
  feedstock uses conda CUDA — `--config=clang_local`, a bundled nvshmem stub
  (`16a3204`), and avoiding hermetic redist downloads.
- **`.bazelrc` accumulation.** `build_common.sh` appends to `.bazelrc`. Running
  it twice without resetting accumulates duplicate/stale lines. It restores
  `.bazelrc` from `.bazelrc.conda-orig` at the top of every run — keep that
  behavior; it is what makes the debug loop idempotent.
- **`xxd`** is needed for TF 2.21.0's XLA genrule — added via `vim` (`c0060b5`).

---

## 10. Disk management

These builds consume tens of GB. The session hit a real disk-full wall.

- A full TF Bazel build's disk cache is a few GB; `output/bld/` per attempt is
  several GB more; ~40 stale `output/bld` dirs accumulated before anyone noticed.
- When space runs low, clean **only** build dirs of attempts that already
  succeeded — the user asked for exactly this ("cleanup old results that have now
  passed successfully"). Do not delete in-flight build state.
- Bazel marks its install tree read-only, so `rm -rf` silently fails — `chmod -R
  u+w` first, or use `find -delete`.
- The host `--disk_cache` mount (`~/tf-cuda-debug/bazel-disk-cache`) is
  content-addressed and *safe to keep* — it accelerates the next run. Clean
  `output/bld/` and stale containers, not the disk cache.

---

## 11. Working effectively with the user

- **The user pushes commits.** Claude has no SSH key. Commit locally, then *tell
  the user the commit hashes to push* — do not attempt to push.
- **Raw, faithful status reports.** The user wants honest status: what built,
  what failed, what is suspect, what went wrong. When a fix was wrong, say so
  plainly (the session did this — "this had a real stumble I need to flag"). Do
  not present a shaky fix as solid.
- **Always state the local time** of the current update and the next one.
- **Follow siblings, don't guess** (§5) — this is an explicit, repeated
  preference.
- **Persist on long grinds.** The user explicitly said "never stop", "don't give
  up", "spawn agents to troubleshoot as needed". The expected loop is:
  apply fix → restart build → arm a background-shell checkpoint → on failure
  spawn a troubleshooting agent → apply its fix → repeat.
- Keep `MEMORY.md` and the indexed project memory file current — the build
  spans multiple context windows, and the memory file is what carries state
  (current build number, branch, commit range, what is still TODO) across them.

---

## The single most valuable lesson

**Copy from a sibling feedstock; do not hand-craft.** Every wrong turn in this
session — the clang-gating selector that broke the CPU build, the forbidden
`PROTOBUF_NO_THREADLOCAL` macro, the wrong migrator type that dropped CPU
variants, the version-mismatched Python-header hack — was Claude inventing a fix
instead of finding the proven one. Every durable fix came from mirroring
`pytorch-cpu-feedstock` (CUDA policy), `jaxlib-feedstock` (clang + CUDA wiring,
zip groups), or a verbatim conda-forge migrator. When something needs fixing, the
first move is not "what flag would fix this" — it is "which sibling feedstock has
already solved this, and what exactly did they do".
