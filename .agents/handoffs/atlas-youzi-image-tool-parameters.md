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
Qwen-Image 2.1 acceptance will be recorded below after installation. No public release or
remote generation is part of this task. Existing main-worktree edits are preserved.

Next: Harbor uses the full sidecar packaging workflow for public distribution;
local incremental delivery must patch verified sourceless modules and re-sign
as described in `docs/engineering/operations/youzi-delivery.md`.
