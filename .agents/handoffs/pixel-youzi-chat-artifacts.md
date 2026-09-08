# Pixel → Atlas: chat artifact previews and image-owner fix

- Owner/host: Pixel, local Mac. Branch: `pixel/youzi-image-tool-failure`.
- Base: `717e4455` from `pixel/youzi-markdown-table-fill`, preserving the delivered
  native model table, compact model header, mode switch and Markdown table fix.
- Dedicated Git worktree. Role files/Orca are unavailable; no agent delegation.
- Receiving owner: Atlas for review of the narrow backend lifetime repair and
  later main integration. No public API or residency policy change.

## Verified

- Successful image tool receipts were persisted with saved artifact/file UUIDs,
  but both chat renderers showed only ToolCallChip, with no artifact projection.
- Both modes now render one shared, task-validated output card outside the chip.
  Existing managed files, thumbnails, playback and image/video overlay are reused.
  Audio and HTML have direct actions; no duplicate file or chat schema created.
- Python selected regression suites: 263 passed, including five owner/cancellation
  regressions with a fake thread-bound model.
- Native selected tests: 40 passed, including isolated visual rendering. Receipt restore,
  all four output kinds, rejecting unsafe/mismatched references, localized image
  failures and existing media lease/playback coverage are included.
- Actual cached Z-Image, fixed source with bundled dependency runtime, offline,
  Apple M5 Max/128 GiB/macOS 26.6.2: preload plus 3 sequential 512-square/4-step
  renders from distinct caller threads all produced decodable nonuniform PNGs;
  owner cleanup completed. No model downloads or user domain writes.
- Shared-component screenshot fixtures passed. In the paired Release candidate,
  a real historical image receipt renders beneath its collapsed tool in both
  Simple and Professional chat. Clicking opens the media overlay in both modes;
  Simple mode zoom changed from 100% to 125%, and closing restored the transcript.
  Two successful historical audio receipts also show inline Play controls.
  No new user prompt, model download or expensive video generation was needed.
- Complete Release build, deep/strict signature verification, bundled resource
  verifier and embedded `rapid-mlx --version` passed. Candidate identity is
  `candidate-ab59e332`; native version remains 0.14.4 (174).
- Extra `ChatRestoredToolsGoldenTests` crashed for a missing `YouziI18nConfig`
  environment. The pre-existing base Release test binary failed identically
  with `--skip-build`. This baseline harness issue is not a passing test; the
  selected 40-test native result above is not a claim that the full suite passes.

## Backend risk / review

Serializing `to_thread` calls did not preserve the image model's MLX owner.
The per-image worker owns load/render/encoding/release, drains cancellation and
retires once stopped. It deliberately does not use chat's worker, to avoid long
denoise jobs blocking chat/audio or tying image lifetime to chat switching.
Failed/canceled dynamic preload drains and closes the orphan adapter.

Review multi-image-instance interactions and other image families separately;
the live reproduction and correction acceptance covered Z-Image. No global MLX
stream mutation, forced unloading of another modality or raw error persistence.

## Delivery and next action

- Main and the installed app are untouched. No release authorized for this task.
- On 2026-09-08, confirmed the previous client had empty input and no model-service
  listener, quit it normally, then launched the new paired Release candidate
  with `RAPID_DESKTOP_NO_PORT_SWEEP=1`. Verified the process executable belongs
  to this task worktree. The old sibling candidate remains intact for rollback.
- The client is left in Simple mode on the historical image chat with its new
  card visible. The model server was not started; history/preview acceptance
  is not a fresh packaged-client LLM-to-multimodal roundtrip. Actual image
  generation was verified separately using the fixed source and bundled deps.
- Audio Play controls were inspected but not audibly exercised in this GUI pass;
  video/HTML UI coverage remains the synthetic fixture and selected media tests.
- Use `RAPID_DESKTOP_NO_PORT_SWEEP=1` for every native test/build/launch. Never
  modify the running sibling worktree's bundle.
- Next optional acceptance: start an already downloaded model through the UI
  and run a fresh multimodal conversation; separately repair the baseline Golden
  test environment without mixing it into this focused diff.
- Integrator: review this task branch together with its prerequisite UI branches,
  not an isolated cherry-pick onto old main that drops recent user work.
