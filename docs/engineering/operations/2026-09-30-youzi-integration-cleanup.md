# Youzi integration and recoverable worktree cleanup — 2026-09-30

Owner: Atlas, Local Mac. Source integration was explicitly authorized by the
user, including resolving outstanding work and retiring integrated directories.
Role files and Orca were absent; each implementation used an isolated Git
worktree. Main started at `8137ae0f`.

## Result and accounting

The September 15 candidate's 33 commits are integrated, together with the
project-positioning branch, the patch-equivalent tray branch, and the completed
memory and video-tool diagnostics. All pre-existing local branch tips are
ancestors of the integration candidate. No rewrite or branch deletion is needed.

| Original worktree | Resolution |
| --- | --- |
| `youzi-integration-20260915` | Combined product chain included; inherited baseline failures resolved |
| `Youzi-chat-video-tool` | Product commit included; pending diagnostics and bundled protocol probe committed |
| `Youzi-memory-unification` | Completed schema-v4 migration, legacy facade, local opt-in queue, confirmation, bounded context and deletion failure handling |
| `Youzi-project-positioning` | History merged; existing feature docs and attribution retained |
| `Youzi-ui-verify` | Its immutable patch has the exact stable patch ID of already-merged `def79da65`; no duplicate source replay |
| `Youzi-complete` | Product HEAD already included; all 66 unique historical prototype files preserved exactly in the documented dormant archive |
| `Youzi-multimodal-tools` | Already represented in main; its three QA artifacts preserved before earlier recoverable cleanup |

The historical prototype archive is under
[`docs/engineering/archive/2026-09-02-youzi-prototypes`](../archive/2026-09-02-youzi-prototypes/README.md).
It is outside the Swift targets and is not a delivery claim for its dormant
SQLite, automation, capability or voice implementations. Activating those old
alternatives would introduce duplicate authorities and incomplete composition.
The decision and per-file hashes make their source recoverable from Git without
keeping an unfinished application worktree. Old raw Butler execution notes stay
in the local recoverable archive rather than in tracked documentation.

## Problems resolved

- **Numerical parity:** M5/MLX's default float32 tensor path and row-vector path
  used different effective precision. The test harness sets `MLX_ENABLE_TF32=0`
  before MLX import, with explicit process overrides preserved. Original 0.002
  tolerances remain; deterministic seeds cover full versus cached decoding.
  Production inference precision is unchanged.
- **Audio discovery:** A fixture mounted only models routes while the production
  gate inspected the canonical audio-registration state. Fresh app isolation and
  explicit mounted/unmounted cases remove test-order leakage.
- **Memory persistence:** Corrupt files remain intact and unwritable across
  restarts; legacy import commits before archive cleanup; candidate confirmation,
  cancellation and deletion errors are surfaced. Remote chat receives no memory
  context. Schema-v4 downgrade requires restoring a backed-up older store.
- **Swift 6.4 compilation:** HTTP transport maps its tuple result to explicit
  named fields, satisfying the newer compiler without changing behavior.
- **Video capability crash:** Release compilation with Swift 6.4 whole-module
  optimization reproducibly crashed in fixed-size capability validation. An
  extracted harness using actual production `VideoCapabilities` reproduces the
  crash with the original `allSatisfy` expression. An equivalent explicit loop
  preserves nonempty and parse-all validation and completes 1,000 calls under
  the same optimization. The speculative encoding change was reverted; the
  production correction stays in the validator. Tests and assertions are
  unchanged. This establishes an affected optimization pattern, without claiming
  a proven compiler-internal ownership cause.
- **Language test isolation:** The golden chat fixture registered English in a
  process-wide defaults fallback, so another unique suite read English while
  expecting its default system language. Suite-local storage replaces that
  registration. Original language and golden assertions remain unchanged;
  production preferences are unaffected.
- **Sidecar audio dependencies:** The trim removed `scipy.io` although music WAV
  conversion imports it. Packaging now retains it and runs a synthetic conversion
  in the post-trim audio smoke, with a matching source contract test.

## Verification

Environment: Apple M5 Max, arm64, macOS 27.0 (26A428), Swift 6.4, Python 3.12.13,
MLX 0.32.2, mlx-lm 0.31.3. Native runs use
`RAPID_DESKTOP_NO_PORT_SWEEP=1` and an isolated `CFFIXED_USER_HOME`; Python runs
use the repository's network/config/cache-isolation fixtures and synthetic engines.

Final Release native aggregate: **798 passed** — RapidUXTests 62 tests / 2 suites,
RapidTests 736 tests / 99 suites; both complete Swift Testing summaries and
process exit zero. The unchanged video-capabilities dispatch and language
persistence tests pass. Native build-start source is `e2279c6e`; subsequent
changes are verified AST-identical Python formatting and documentation, with no
Swift or package configuration change. Final Python source is `12a6ad83`.
The earlier native crash and intermediate one-issue run remain in the evidence;
only these final complete passing runs establish source acceptance.

Native reproduction uses `swift test --package-path apps/rapid-mac -c release -j 6
--disable-automatic-resolution --filter` with the recorded integration selection;
the cleanup evidence retains the exact command, source SHA and full log. The
focused original crash is covered by unchanged `YouziLocalModelToolsTests`
and `videoCapabilitiesDispatch`. The WMO forensic runner is preserved with the
evidence, including expected original failures and final valid/invalid probes.

Final Python audit selection: **3,800 passed, 10 skipped, 11 deselected** across
150 test files; zero failures/errors. Full SciPy comes from a task-local read-only
symlink overlay and mflux from the existing packaged dependencies, with import
provenance asserted. This closes the earlier dependency-only failures without
installing into shared environments. The independent image suite passed 22
checks; voice report passed 7; those overlap other selections and are not added
to the aggregate count.

Changed Python syntax and lint passed for 37 active files. Final repository-wide
Ruff lint and formatting checks pass (1,313 formatted files). The 19 formatting
corrections have identical parsed ASTs including constants, and a fresh full
Python rerun verifies the final tree. Workflow SHA pinning and expression checks
pass for 18 workflows; generated model architecture and version synchronization
(0.14.4) pass. Shell syntax, Git whitespace and relative docs links pass. Prototype integrity verification proves
66 exact files / 1,173,954 bytes, with no symlinks. Independent acceptance and
local raw logs are recorded by the task's Butler gate and copied into the cleanup
record before its worktree is moved.

These are development-source checks. No release was published, installed app
replaced, real model weights loaded, production data migrated or microphone used.
A newly built distribution still needs its normal packaging/signing and live
acceptance before release. Existing schema data is not silently downgraded.

## Cleanup and recovery

Only after origin/main contains the accepted result: recheck every worktree HEAD,
tracked diff, untracked snapshot/hash and runtime/active-task use. Preserve all
branch refs, QA artifacts, ignored output and old execution records. Move whole
directories with the macOS FileManager Trash API, back up each Git registration,
preview prune and require its exact set to match the moved directories, then
verify the remaining worktree list.

The local cleanup record stores original path, branch, commit, exact Trash path,
registration backup and verification evidence. To recover, confirm that neither
original path nor registration path has been recreated, move the directory back,
restore its registration backup, run `git worktree repair ORIGINAL_PATH`, and
verify HEAD/status. Never overwrite newer work or empty Trash during this task.
Two `Youzi-safety-*` directories and `Youzi-visualizations` are ordinary backups
and an HTML artifact; they are preserved separately from Git worktrees.
