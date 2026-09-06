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
