# Youzi media repair / 0.14.3 delivery

Atlas owns integration/release; Harbor owns hosted packaging. Local Mac validation.
Task branch: `atlas/youzi-media-release`; base: gallery `3f24eff1`, merged upstream
`8530d6b9`. Role instruction files are absent from this checkout.

## Confirmed causes

- `voice: Chinese` yields HTTP 400 `invalid_voice`. Language labels are not Qwen
  speaker IDs. The tool now validates speakers, advertises `youzi_speech_voices`,
  defaults to the alias-keyed saved voice, and renders allowlisted recovery copy.
  Canonical HF identity avoids selecting the bf16 model when 4bit is intended.
- The old installed sidecar lacked `mlx_video`; additionally, dynamic residency
  explicitly rejected `video-gen`, and video routes only read the chat-primary
  engine. New packaging includes audited video dependencies; dynamic startup and
  exact registry routing now retain the chat primary. Queued/running video work
  leases its engine, including uncancellable generation after request cancellation.
- Wan cached checkpoints are resolved before contacting the Hub. Wan/LTX upstream
  materializes weights inside generation, not at service preparation. Do not claim
  that a prepared video adapter has all its weights permanently on the GPU.
- The previously failed hosted build timed out type-checking ContentView. The
  gallery branch's extracted view surfaces are preserved through the merge.

## Gates and rollback

Always run Swift checks with `RAPID_DESKTOP_NO_PORT_SWEEP=1`. No model-cache deletion,
port sweeps, secret logging, or preference reset. Preserve Youzi UI when resolving
upstream conflicts. Keep merged vendor resources byte-for-byte (upstream Mermaid
contains template-literal whitespace; do not auto-format it).

Before installation back up the whole installed/running app, runtime override and
Rapid user data. Quit the exact running app normally. Install a fresh, fully sealed
bundle; do not overlay-copy signed resources. The new versioned bundled runtime
outranks the old override. Roll back app/runtime from backup without overwriting
new user-created files or conversations.

Hosted `youzi-package.yml` runs scoped Swift regressions, builds the complete
sidecar, verifies code signatures and publishes ZIP, DMG, sidecar, checksums and
`latest.json` into a **draft**. Promote only after native-client acceptance.
GitHub's `/releases/latest/download/latest.json` excludes drafts/prereleases, so
only a formal release reaches updater discovery. Builds are ad-hoc signed, not
Apple-notarized; no Gatekeeper-ready distribution claim.

Local evidence before native acceptance: merged release executable compiled;
175 Swift tests / 27 suites passed; 266 backend tests plus 3 new video routing,
lease and dynamic-loader regressions passed; fresh sidecar import/Metal/FFmpeg
smokes passed. Actual video generation, new-client acceptance and hosted release
status must be recorded after execution, not inferred from these checks.
