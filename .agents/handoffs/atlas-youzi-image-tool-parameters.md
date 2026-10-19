# Atlas → Pixel / Harbor: image tool parameters

Owner: Atlas; host: local Mac; branch: `feat/youzi-image-tool-parameters`.
Read AGENTS.md and image/remote delivery handoffs; role files are absent.

The local conversational image tool now accepts per-call seed, steps, guidance
and negative_prompt. Schema and runtime validation bound values before startup
approval. Defaults and saved preferences remain unchanged. The image client
forwards only supported local extensions; generic remote gateways reject these
new controls rather than silently discarding them.

The image runtime returns per-image parameter receipts from the actual render,
including random seeds and actual output dimensions. Receipts use request-local
storage and the existing GPU owner thread, avoiding shared last-result races.
Old engines still work without fabricated receipts. Backend model constraints
return HTTP 400 instead of a GPU failure, including Qwen-Image 2.1's paired CFG /
negative-prompt requirement and controls ignored by distilled backends.

Verification: 336 Swift tests in 56 suites and 221 Python tests pass, covering
tool/client/remote contracts, per-call defaults, receipts, model constraints,
thread affinity and existing image backends. The final client compatibility
change also passed its focused suites. Local application rollout and real
Qwen-Image 2.1 acceptance are recorded below. No public release or
remote generation is part of this task. Existing main-worktree edits are preserved.

Next: Harbor uses the full sidecar packaging workflow for public distribution;
local incremental delivery must patch verified sourceless modules and re-sign
as described in `docs/engineering/operations/youzi-delivery.md`.

## Local acceptance, 2026-10-19

- Installed complete native `candidate-ea248287` after normal quit. Bundled
  0.14.4 runtime retains mflux 0.20.0; four changed modules matched normalized
  baseline code objects before sourceless patching. Deep strict signature and
  framework rpath verified. Inactive 0.13.3 override retained and backed up.
- Native UI reports chat, ASR, TTS and image availability after restart. Original
  local Qwen3.8 service is ready; no model preference changes were made by this task.
- Official OpenAI SDK against an isolated instance of the installed runtime:
  incomplete Qwen CFG fails with HTTP 400; default 40-step / guidance 1 and
  explicit 8-step / guidance 2 / negative prompt both generate valid 512×512 PNGs.
  Receipts report seed 4242, actual steps, size, guidance and negative conditioning.
  Two identical 8-step requests produced byte-identical PNGs. This is a same-build
  functional check, not a reproducibility guarantee across runtimes or hardware.
- Apple M5 Max / 128GB, pinned native q4 weights, mflux 0.20.0: wall times were
  61.85s (40 steps), 25.66s and 27.23s (8 steps with CFG). Other models were running;
  these are single acceptance runs, not comparative throughput benchmarks.
- Authenticated SDK model list/retrieve passed on the isolated image service;
  it stayed healthy for 114.86s and was then stopped. Images were visually inspected.
- Full app/runtime/preferences backup, synthetic prompts, reproduction script,
  output PNGs, parameter receipts and verification logs are retained in the local
  Client Backups directory. Rollback restores the whole saved app after normal
  quit; do not overwrite current user settings or remove model files.
