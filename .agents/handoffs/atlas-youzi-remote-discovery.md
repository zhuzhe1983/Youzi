# Atlas → Pixel / Harbor: remote media discovery

Task branch: `feat/youzi-remote-model-discovery`, base `27ad820b`, local Mac.
Atlas owns integration; Pixel UI changes are scoped to the existing remote editor.
AGENTS.md and the previous remote-model handoff were read; role files are absent.

## Verified

- Discovery classifies explicit tasks/endpoints/output modalities before family
  name hints. Input vision/video is never sufficient for generation. Unknown
  aliases remain accessible through show-all, search and manual ID entry.
- New configurations can explicitly reuse a saved provider at the exact same
  normalized API base. Keys stay in Keychain, with independent items after save.
  Changing host/path cannot silently transfer the source credential.
- 322 tests in 39 suites pass with `RAPID_DESKTOP_NO_PORT_SWEEP=1` and
  `YOUZI_REMOTE_VISUAL_QA=1`, using the operations guide's focused Swift filter.
  Includes classification, credential boundaries, existing media transport,
  video session pinning, selection and bilingual native rendering.
- A read-only user-provider catalog contained 100 IDs, without capabilities:
  10 image, 10 video, 8 audio, 62 chat hints; 4 unknown and 6 other-purpose IDs.
  These are aliases, not counts of distinct models or verified integrations.
  No keys, private provider URL, response bodies or generated assets are tracked.

## Remaining provider acceptance

- User identified the gateway as CLIProxyAPI/Management Center. Upstream source
  `2422c6b0` declares images at `/v1/images/generations`, native xAI videos at
  `/v1/videos`, and OpenAI video compatibility at `/openai/v1/videos`.
  Missing `GET /v1/videos` history explains 404; it does not disprove generation.
  All three deployed POST routes reject malformed JSON with 400 before inference.
- Added explicit CLIProxyAPI video mode: compatible create/poll/content paths,
  JSON reference image, session history, retained creation metadata on sparse
  polls, and no unsupported history/delete requests. Supports the three verified
  Grok Imagine Video IDs; MiniMax-H3 and lite remain unsupported by this adapter.
- No real remote inference or billing probe was performed. Do not label the
  discovered candidates as available generation models without protocol checks.
- Existing chat selection and local Qwen-Image 2.1 recommendation are preserved;
  no discovered model is silently added or selected.
- No backend routing, public API proxy or chat-tool permission changes.

Next: Pixel can select a saved service, choose Images/Video, discover and search
the filtered directory. For this gateway choose CLIProxyAPI video mode. Actual
remote generation requires a user-requested task; no billed QA was run. Harbor
retains the complete app/runtime backup for local rollout and rollback. Public
release remains outside this task.

## Local delivery, 2026-10-19

The native release candidate `candidate-f330e83c` is installed in the existing
Workspace Preview app. Its unchanged, previously verified 0.14.4 runtime retains
mflux 0.20.0 and Qwen-Image 2.1. Complete app/runtime/preferences backups and
verification logs are retained in the local Client Backups directory; see the
operations guide for rollback. Existing main-worktree edits are unchanged.

Native Settings successfully reused the saved gateway and filtered its actual
100-ID catalog into 10 image and 10 video candidates. The CLIProxyAPI selector
and supported-model limitations were inspected. The draft was cancelled; no
configuration or generation was submitted. Settings was closed afterward.

The local Qwen chat service was restarted through the model-file load action;
the remote chat selection and all model preferences remain unchanged. SDK list
and real Responses checks are included in the local verification evidence.
Authenticated model-detail parsing was not repeated because the test process
cannot read the app's keychain item; the unchanged runtime passed this check in
the previous delivery, and anonymous model-detail requests still return 401.
