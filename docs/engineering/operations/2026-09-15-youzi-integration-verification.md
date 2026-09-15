# Youzi integration verification — 2026-09-15

Owner: Atlas, Local Mac. Verification branch: `atlas/youzi-integration-verify-20260915`.
Role files and Orca are absent; work uses an isolated Git worktree below the
workspace's `.worktrees/` directory. The user's running client is not replaced.

## Candidate and scope

- Base: `origin/main` / `main` at `8137ae0f`.
- Product chain: `pixel/youzi-composer-model-controls` at `2a31f692`, 31 commits
  ahead of main. Main is an ancestor, so the chain fast-forwards cleanly.
- Independent measurement: `youzi/voice-latency-timeline` at `3da34caf` adds one
  unique commit. Its merge with the product chain has no content conflicts.
- Dirty memory migration, old UI verification edits, and uncommitted video-tool
  diagnostics remain outside this candidate. No release or production deployment.

## Repairs discovered by verification

1. The residency API advertises `supports_preserve_loaded: true`; an older
   whole-response assertion omitted this field. The test now verifies the field
   while retaining the complete model/audio snapshot assertion.
2. Ruff found 16 new issues: import ordering, a nested context manager, and
   multiple statements per line. These were corrected without changing routing.
3. The inherited `GoldenChatSurface` omitted the required `YouziI18nConfig`
   environment and trapped before the restored-conversation journey could run.
   Both mount paths now supply an English config with a fresh defaults suite and
   in-memory registration; they do not write the user's language preference.
   The pre-repair helper and restored-tools test are byte-identical to main;
   earlier branch handoffs also record the same trap. The candidate reproduces
   it in isolation. A fresh native main build was not run in this audit.
4. The video polling test asserted preview availability as soon as server job
   status completed, before the asynchronous preview request finished. Its
   bounded wait now covers both active jobs and preview loading, retaining all
   final assertions. No production video behavior was changed by this repair.

## Environment

- Apple Silicon, macOS 26.6.2 (25G83); Swift 6.3.3; Release configuration, 6 jobs.
- Swift dependency pins: NetworkImage 6.0.1, Sparkle 2.9.5, swift-cmark 0.8.0,
  swift-markdown 0.8.0, swift-markdown-ui 2.4.1. The existing candidate's generated
  lockfile was copied to reproduce dependency versions, not sibling source edits.
- Lockfile SHA-256: `ad04282d0e24e688d3b9f2b92326762d19a30a69e384203586c6c83b9bac2bf6`.
- Python 3.12.13, pytest 9.1.1, pytest-asyncio 1.4.0, FastAPI 0.141.1,
  httpx 0.28.1, NumPy 2.5.2, MLX 0.32.2, mlx-lm 0.31.3, Ruff 0.16.6.
  A pre-existing virtualenv supplies dependencies read-only; `PYTHONPATH` points
  first at this worktree. That environment lacks mflux.
- The supplementary image probe uses the already-built candidate's paired
  interpreter and packaged dependencies, including mflux 0.19.0; pytest alone
  is supplied by the test environment. It performs no real model inference.
- Every native invocation sets `RAPID_DESKTOP_NO_PORT_SWEEP=1`; tests also set
  `CFFIXED_USER_HOME` to a temporary test home. Python tests use the repository's
  hermetic network/config fixtures, excluding network and real-cache opt-ins.

## Results

| Check | Result |
| --- | --- |
| Actual merge and whitespace check | Pass |
| Direct changed Python suites, before repairs | 124 passed |
| Focused Python regression after repairs | 308 passed |
| Broad Python regression after repairs | 3779 passed, 3 failed, 24 skipped, 11 deselected |
| Packaged-dependency image regression | 1 passed, resolving the missing-mflux environment failure |
| Changed Python lint | Pass after fixing 16 issues |
| Python syntax | Pass |
| Native Release executable and test compilation | Pass, first clean build 423.42 s |
| Native final Release regression | 736 tests in 95 suites passed, including restored-tools and video polling |
| Standalone voice playback probe compilation | Pass using its production sentence segmenter |
| Existing latest candidate resource verification | Pass; this is not a newly packaged merged app |

Counts overlap; do not add them together. A broad Python pass is not claimed.

### Baseline failures and limits

- `test_bailing_hybrid_model.py::test_forward_and_cache_parity` and
  `test_muse_glimmer_model.py::test_forward_softcap_and_cache_parity` exceed their
  0.002 numeric tolerance in this environment. Both reproduce on an exact
  `git archive origin/main` source copy with the same Python/MLX environment.
  These test files are unchanged by the product chain. No tolerance was relaxed.
- `test_image_weight_precision.py::test_packaged_bf16_uses_model_path_without_onload_quantization`
  cannot import mflux in the general test environment on either main or candidate.
  It passes with the existing app's full dependency runtime.
- `test_audio_routes_bundle.py::TestDeepProbeSurfacesDegradedLane::test_models_endpoint_surfaces_lane_status`
  fails in isolation on both main and candidate (`audio_lanes` is absent), although
  the broad run passes it. This is an inherited order-sensitive regression and
  remains unresolved. Its full-suite pass must not be used as proof of a fix.
- No fresh remote-provider generation, physical microphone/AEC, acoustic onset,
  model downloads, data migration, app restart, or release acceptance was performed.
  Existing candidate startup was observed earlier in this user session.

## Reproduce

Run from the candidate worktree. Set `TEST_PYTHON` to an environment matching
above and `LOG_DIR` to a temporary output directory. Never point tests at a real
model cache or a live service.

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 CFFIXED_USER_HOME="$LOG_DIR/native-home" \
  swift test --package-path apps/rapid-mac -c release -j 6 \
  --filter 'Youzi|RemoteModel|ModelServiceAuth|ModelAPIAccess|ModelGenerationDefaults|SettingsVoicePreview|CustomInstructions|BrowseProxyCompatibility|SidecarBuildScript|StreamingRowIsolation|CurrentDateTimeContext|MarkdownTable|MenuBarStatus|ExternalModelCatalog|ModelSurfaceRedesign|SettingsVisualFoundation|Video|AudioClient|ChatStream|ModelReadiness|ModelSelection|ModelPicker|SettingsEnvironment|SettingsDeepLink|LiveVoice|ServerResidency|ChatRestoredToolsGolden|GoldenChatSurfaceTests'

PYTHONPATH="$PWD" PYTHONDONTWRITEBYTECODE=1 "$TEST_PYTHON" -B -m pytest -q \
  tests/test_audio_pcm_streaming.py tests/test_image_worker_affinity.py \
  tests/test_ltx23_video.py tests/test_youzi_audio_preload.py \
  tests/test_youzi_model_loading_policy.py tests/test_youzi_startup_models.py \
  tests/test_audio_model_worker.py tests/test_resident_models.py tests/test_http_auth.py \
  scripts/benchmarks/test_youzi_voice_latency_report.py

RAPID_DESKTOP_NO_PORT_SWEEP=1 swiftc -swift-version 6 -O \
  scripts/benchmarks/youzi_voice_playback_probe.swift \
  apps/rapid-mac/Sources/Rapid/LiveVoice/LiveVoiceSentenceSegmenter.swift \
  -o "$LOG_DIR/voice-playback-probe"
```

The broad Python selection is the 150 top-level `tests/test_*.py` files whose
names match `residen`, `policy`, `audio`, `anthropic`, `response`, `completions`,
`image`, `video`, `model`, `chat`, or `http_auth`. Use
`-m 'not requires_network and not real_hf_cache'`; preserve failures instead of
silently excluding their test nodes. Raw local logs and XML are under
`/tmp/youzi-integration-20260915/`, not committed.

## Conclusion

The combined product chain and measurement commit are conflict-free. Release
compilation, the final selected native regression, repaired Python suites, lint,
and resource checks pass. The integration-specific failures found by this audit
were corrected. The entire repository is not all-green: the baseline failures
above and unperformed real-service acceptance remain explicit review limits.
Main was not updated by this verification task.

## Next owner and integration boundary

Atlas owns review and integration of this branch. Vector should investigate the
two inherited numeric comparisons with the recorded environment. Atlas should
repair the isolated model-discovery/audio-health regression separately. Harbor
should run normal CI and package/rollback checks before any authorized release.
Keep main and the currently running candidate intact while these results are
reviewed; the uncommitted memory migration still requires its own validation.
