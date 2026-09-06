# Atlas → Atlas / Harbor: loaded-only full model discovery

- Date: 2026-09-06; owner Atlas, host Local Mac.
- Branch: `atlas/openai-loaded-models`; API-specific completion, not a remote merge.
- AGENTS.md was read. `.agents/roles/` is absent in this local application
  checkout; no role file could be read.
- User's latest choice supersedes the minimal-response/metadata-route plan:
  retain `/v1/models` extensions and aliases, keep only loaded models, and
  preserve OpenAI-compatible base fields plus Codex's additive catalog.
- Durable contract and reproducible verification scope:
  `docs/engineering/decisions/2026-09-06-youzi-loaded-model-discovery.md`.
- Verified: strict official SDK list/retrieve parsing against the new ASGI
  route, actual internal Agent adapter parsing, lifecycle and multimodal
  profile tests. These tests use stub engine state, not concurrent weights.
- Current working-source verification: model/residency/Responses/auth suite
  844 passed, 2 skipped (official SDK 3.8.0 enabled); Agent/audio/routes suite
  666 passed, 12 skipped; scoped Ruff checks and `git diff --check` passed.
- Independent committed-source verification: `b4ea91bd` was checked out in
  a clean detached worktree. A combined model/residency/Responses/Agent/audio/
  routes/capabilities/auth regression run passed **1480 tests, 14 skipped**
  with official SDK 3.8.0 strict list/retrieve checks enabled. Import location
  was asserted to be the clean worktree, not the dirty application checkout.
  The uncommitted anonymous-auth batch was intentionally absent from this run.
- Risk: the installed app's sourceless Python runtime is still the previous
  build. Source/test completion is not a live runtime update. Full current
  application batch packaging and native QA remain separate delivery work.
- Risk: preexisting uncommitted UI/settings/auth/image work must remain out of
  this commit. Remote integration is still postponed until that batch is
  verified; do not bulk-stage or overwrite local UI with remote changes.
- Existing limitations outside this patch: simple-chat context-ring estimate;
  Agent adapter does not send configured bearer credentials on discovery.
- Next action: Atlas finishes the pending local application delivery and
  verifies live list/Responses + auth-save behavior, then reviews remote
  integration independently. Harbor's README archive/rewrite is already on
  its separate documentation branch; do not conflate it with application
  source or claim it has been merged into main.
