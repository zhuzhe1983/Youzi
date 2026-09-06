# Atlas → Atlas / Pixel / Harbor: multimodal delivery

Date: 2026-09-06. Host: Local Mac. Branch: atlas/youzi-multimodal-tools,
based on local-delivery 6ec648e6. Main and other worktree source left untouched.
Role files absent from this checkout.

Implemented: downloaded scene picker + occupancy; five native multimodal tools;
shared human load approval; scoped PNG/WAV/HTML artifacts; 3 ordinary /24 local
multimodal call budget; opt-outs preserved. Operational contract and limitations:
`docs/engineering/operations/youzi-multimodal-tools.md`.

Verified: focused 190 Swift tests /29 suites, release build, deep strict ad-hoc
signature; isolated actual LLM/image/TTS/offline HTML test. No video/STT tool.
Runtime is verified incremental co-residency runtime, not clean-room rebuild.

Installed 0.14.2 (172) in /Applications, with matching runtime override. Complete
backup is under Application Support/Youzi-Backups (local QA file records path).
Native GUI image was saved, but UI became unresponsive in layout before audio /
HTML. Normal quit timed out. Backend healthy. No force kill, no public release,
no updater feed. **Do not publish as verified.**

Local diagnostics in /tmp/youzi-delivery-qa; these contain local UI state and must
not be committed. They include backup-path, main-thread sample and AX snapshots.
190-test rerun log: /tmp/youzi-0142-regression.log. Package log:
/tmp/youzi-0142-package.log. Prior isolated real-model evidence remains separate
from GUI acceptance. AX set-value did not update SwiftUI binding; future driver
must paste/type and verify resulting message, without sending an existing draft.

Next action: user approval for exact-process forced recovery is needed because
normal quit failed. After recovery, Pixel/Atlas diagnose layout stall and rerun
actual native full flow. Harbor publishes only after successful GUI acceptance.
Source is committed for handoff, not integrated into delivery/main or tagged.
