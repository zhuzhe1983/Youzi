# Atlas → Harbor: Youzi media release

Branch `atlas/youzi-media-release`, merges origin/main `8530d6b9` while retaining
local Youzi UI. User authorizes restart, main integration and formal Actions release.
See `docs/engineering/operations/youzi-media-release.md` for confirmed causes,
verification and rollback. Native acceptance / hosted packaging remain to run;
do not publish based solely on compilation. No roles directory exists locally.

Additional local acceptance: both cached Wan I2V and T2V generated tiny MP4
smokes with the complete sidecar. Found and repaired a locked-session legacy
Keychain launch stall and merged port-precedence regression. Full fresh app is
installed and relaunched from /Applications; bundled runtime now healthy on
8000. 204 Swift / 269 Python checks pass. Desktop session is locked: native
interaction is pending unlock, not a claimed pass. Integration API checks and
hosted draft packaging are next; formal publication remains gated on acceptance.


Follow-up: real OpenAI Responses + video-job API and the complete live
LLM/image/TTS/HTML toolchain passed. Actual installed app stays healthy; desktop
still locked. Hosted package run 34050472203 failed only at stage VERSION lookup;
final-app manifest/archive fix and three regressions are ready for a new run.
Merge CI fixtures/types/accessibility and upstream provenance are reconciled;
151 Swift/272 Python scoped tests, Ruff and pinned mypy budget pass.
Next: dispatch updated main, inspect hosted assets, then native acceptance and
formal promotion. No release exists at this point; do not promise GUI acceptance.


Expanded tests: 319 reconciliation and 114 audio-contract checks pass. The
installed-client official OpenAI SDK also completed Responses and generated
218,924-byte valid WAV; invalid Chinese speaker fails early with 400. Mixed
no-MLX-on-Mac broad run is NOT a pass (18,077 pass/83 fail); see operations doc.
Cancelled packaging 34052392766 before draft to include the TTSEngine-specific
local name required by the chat-engine AST gate. Restart packaging from the
new commit. Isolated 18043 is stopped, real client 8000 remains healthy.

Release correction: Actions 34052959770 completed, but installed 0.14.3 crashed
because the template JSON was absent and Bundle.module fell through to a missing
runner checkout. Kept draft unpublished and marked DO NOT PUBLISH. Previous
complete client restored; /health ready on8000. Branch now repairs production
resource lookup/staging, adds a poisoned-fallback relocation regression and
all-JSON packaging gate, and bumps the replacement candidate to0.14.4(174).
Next: hosted build, installed-artifact startup/TTS/video/API verification, then
publish only an accepted candidate. Desktop is still locked (GUI not claimed).


## Current handoff: 0.14.4 formally delivered

Atlas → Pixel / Harbor / Vector. Branch `atlas/youzi-media-release`; source
35e987b4 is on main and tagged youzi-v0.14.4. Actions 34054716370 succeeded;
Engine CI and Youzi desktop CI also passed. Downloaded hosted artifact now
installed, normally restarted and healthy on8000. Actual SDK Responses, TTS,
Z-Image and both Wan I2V/T2V generations passed. Chat/image/speech/Wan T2V service
IDs are available together after the final restart. See operations doc for
exact outputs, accepted scope, rollback and known limitations.

0.14.4 was promoted to formal Latest under user authorization; NOT a blanket GUI
sign-off. Old0.14.3 remains a rejected draft. No source/UI rollback was used.

Remaining concrete work:
- Pixel: after user unlock, click through the real GUI conversation, narration,
  video startup and media preview flows. Screen was locked throughout this run;
  interactive GUI checks are not claimed, and legacy GUI CI jobs remain queued.
- Vector/Atlas: investigate Wan temporal output length. 5-frame requests generated
  decodable8-frame clips at256x256 with default denoising steps. Exact-frame tests
  failed; this is disclosed, not hidden by the generation-smoke pass. Preserve
  model fidelity and add frame-count regression before changing runtime output.
- Harbor: monitor the formal release/updater and retain the rejected draft for
  diagnosis. Package is ad-hoc signed, not notarized. Do not claim permanent GPU
  residency merely because a video adapter is registered.
