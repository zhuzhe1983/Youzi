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
- 320 tests in 39 suites pass with `RAPID_DESKTOP_NO_PORT_SWEEP=1` and
  `YOUZI_REMOTE_VISUAL_QA=1`, using the operations guide's focused Swift filter.
  Includes classification, credential boundaries, existing media transport,
  video session pinning, selection and bilingual native rendering.
- A read-only user-provider catalog contained 100 IDs, without capabilities:
  10 image, 10 video, 8 audio, 62 chat hints; 4 unknown and 6 other-purpose IDs.
  These are aliases, not counts of distinct models or verified integrations.
  No keys, private provider URL, response bodies or generated assets are tracked.

## Remaining provider acceptance

- The saved provider's `GET /videos` returned 404. Its directory alone does not
  establish OpenAI video API compatibility. User was asked for gateway API docs
  or source to determine whether a separate video adapter is needed.
- No real remote inference or billing probe was performed. Do not label the
  discovered candidates as available generation models without protocol checks.
- Existing chat selection and local Qwen-Image 2.1 recommendation are preserved;
  no discovered model is silently added or selected.
- No backend routing, public API proxy or chat-tool permission changes.

Next: Pixel can select a saved service, choose Images/Video, discover and search
the filtered directory. Atlas should evaluate the gateway's actual protocol once
documentation is available; Harbor retains a complete app/runtime backup for
local rollout and rollback. Public release remains outside this task.
