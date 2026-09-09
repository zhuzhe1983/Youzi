# Atlas → Pixel / Atlas / Harbor: remote model supplements

Task branch: `atlas/youzi-remote-models`, base `9de4666f` from the delivered
`pixel/youzi-model-menu-order` branch. Owner Atlas, local Mac; UI touches reviewed
within this scoped task. AGENTS.md read. Role files `.agents/roles/` are absent
and Orca is unavailable in this checkout, so a separate ordinary git worktree
was used. No other worktree's dirty files were consumed or edited.

## Verified

- Local-first global/per-kind priority with secondary optional remote settings;
  API base/model workflow/optional Keychain key; provider discovery and metadata
  editing, enable/disable/prefer/remove. No keys in preferences or documentation.
- App-side chat/ASR/TTS/image/video routing and separate remote picker sections;
  no remote downloads/residency, local bearer reuse or cross-provider retries.
- Video retains the provider snapshot during active work and rejects new
  submissions after disable; explicit idle reconnect applies edited endpoint/key.
- 378 targeted tests / 41 suites passed, including bilingual native fixture
  rendering. See operations doc for command, coverage and acceptance limits.
- No user configuration writes, real provider inference, model load/download,
  service shutdown, main integration or public release as part of verification.

## Candidate delivery

- Native code commit `ffec5c44`, local identity `candidate-ffec5c44`, debug/ad-hoc
  app assembled successfully. Existing version fields remain `0.14.4 (174)`.
- Bundled unchanged runtime from preserved `candidate-6e5aac94` after an empty
  source/recipe/resource diff; full strict codesign verification and bundled
  CLI `--help` passed. See operations doc for exact provenance and paths.
- Candidate not launched; the prior running client was left untouched. This is
  not a main merge, notarized release, or real-provider inference acceptance.

## Remaining acceptance / risks

- Provider-specific live inference is not tested. A `/models` list alone is not
  a capability proof. Never use user's stored keys to run billed QA unasked.
- The public `/v1`, built-in local multimedia tools and Live Voice remain local;
  exposing remote providers there needs a separate explicit consent design.
- Synthetic native layout QA is not a complete GUI-click/network acceptance.
- Real HTTP redirect fixture and unified generation-response byte budgets are
  follow-ups; current download/discovery bounds are documented, not generalized.
- Do not claim unfinished `atlas/youzi-memory-unification` has been merged/tested.

Next action: Atlas reviews/integrates this branch only when requested; Pixel can
walk the added settings/pickers against a user-approved provider. Harbor must
retain the prior candidate for rollback if a later release is authorized.
