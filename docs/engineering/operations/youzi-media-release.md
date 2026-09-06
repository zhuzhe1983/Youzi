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

### Additional acceptance findings (2026-09-07 local Mac)

- Both downloaded Wan checkpoints completed real generation with the packaged
  runtime: I2V q8 (256x256, 5 frames, 1 step, 24.0 s, 12,745-byte MP4),
  T2V (same smoke dimensions/steps, 20.2 s, 5,022-byte MP4). These are runtime
  smoke checks, not quality/performance benchmarks or full-resolution acceptance.
- A real replacement/restart exposed an existing legacy login-Keychain stall
  while the desktop session was locked. `LAContext.interactionNotAllowed` and
  `kSecUseAuthenticationUIFail` each still blocked in SecurityAgent on this
  machine. A separate compiled non-interactive probe with
  `SecKeychainSetUserInteractionAllowed(false)` returned `errSecAuthFailed` in
  11 ms without changing any item. The adapter now sets that process-wide legacy
  gate once, retains LAContext restrictions, and fails unavailable access closed.
  The API is deprecated, but needed for the file-based keychain compatibility
  path; do not silently remove it in favor of the reproduced hanging replacement.
- The rebuilt app was installed as a complete fresh bundle with deep/strict
  signature verification. It now starts its bundled 0.14.3 runtime while locked;
  `/health` returns ready/healthy. No keychain ACL, credential, or lock state was
  changed. Native interaction still requires the user to unlock the desktop.
- Merge regression: upstream default port candidates gained a second range,
  causing Youzi's array-comparison override detection to ignore its saved port.
  Precedence is now explicit: valid environment override > Youzi setting >
  explicit legacy Desktop setting > Youzi's existing 8000...8009 range.
- Fresh scoped verification: 204 Swift tests / 35 suites and 269 Python tests
  passed. The optional native visual suite is skipped unless explicitly enabled;
  it is not counted as an interactive GUI acceptance.


### Integration and packaging follow-up

- The packaged runtime passed an isolated three-model API check: chat + TTS +
  Wan I2V, actual WAV and asynchronous MP4 output, and chat still responding
  afterwards. The official OpenAI SDK decoded `models.list()` and completed
  `responses.create()` against that service.
- The real live Swift toolchain produced an offline illustrated/narrated HTML
  (1,155,766 bytes): model discovery, approved image/TTS loads, voice discovery,
  image generation, speech synthesis and storybook assembly. Approvals were
  simulated explicitly by this test; no user conversation/history was changed.
  This is not native GUI acceptance or a new GUI-visible task.
- Actions run 34050472203 compiled/tested the app and built the complete runtime,
  but packaging failed because it read VERSION from intermediate staging.
  The manifest now reads the final app; the updater archive is also created
  from that versioned final runtime. Three hermetic regressions reject missing
  or stale archived versions and verify manifests without a staging directory.
- Merge-CI reconciliation preserves Youzi branding, configurable image defaults,
  and the concise README; upstream benchmark checks use rapid-mlx-readme.md.
  Added accessibility identifiers without changing layout/actions, isolated
  loaded-audio discovery fixtures and external-LTX fixtures, and adapted private
  video/auth mocks to their actual call signatures. The exact-link cache test
  resolves the current CLI module after completion tests reload it.
- Verification after reconciliation: 151 scoped Swift tests / 28 suites pass;
  272 scoped Python tests pass. Ruff lint/format pass; the pinned Python 3.11
  mypy gate passes with its unchanged 701-error legacy baseline (no new debt).
  A real archive from the final app contains the matching 0.14.3 VERSION.
- Formal promotion remains gated on native-client acceptance after user unlock;
  do not call the failed hosted run a published release.

- Expanded reconciliation checks: 319 Python tests passed (3 opt-in cases
  deselected), followed by 114 audio/route-contract checks. Use a specifically
  named `speech_engine` for the TTSEngine adapter; it is not a BaseEngine and
  must not be mistaken for chat-engine access by the AST contract gate.
- The installed client itself also passed the official OpenAI SDK: model-list
  decoding, a completed Responses request, and a valid 218,924-byte WAV with
  case-insensitive Vivian selection. Explicit `Chinese` speaker returns 400
  before synthesis. Deep/strict code-sign verification still passes afterward.
- A broad no-MLX experiment on this Mac was not a passing suite: 18,077 passed,
  83 failed, 374 skipped. Most failures were Apple-path tests run without their
  MLX packages or native-session prerequisites; the newly exposed audio AST
  naming issue was fixed and rechecked. Use actual hosted Linux/Apple jobs as
  their respective environment gates, not this mixed-environment result.
- Package run 34052392766 passed its manifest and Swift steps but was cancelled
  before draft creation to include the final audio-contract clarification.
  The isolated port-18043 test server was shut down; the actual client on 8000
  remains running. Screen unlock/native acceptance remains outstanding.
