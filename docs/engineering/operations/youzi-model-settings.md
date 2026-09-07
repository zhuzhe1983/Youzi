# Youzi model settings

## Ownership and navigation

Settings → Models is split into six horizontally scrollable tabs. The existing
Settings canvas owns vertical scrolling and the Save footer.

| Tab | Responsibility |
| --- | --- |
| Service | Current loopback API address, preferred port, auto-start and interrupt confirmation |
| Files | Storage roots, linked checkpoints, disk usage, downloads and deletion across capabilities |
| Chat | Existing sampling settings and per-model KV cache / speculative decoding / prefix cache |
| Audio | Default voice **per model**, shared speech speed |
| Images | Default aspect and long-edge resolution |
| Video | Video workspace opt-in and capability-validated size / duration defaults |

Legacy model-management links open Files, performance links open Chat, and
experimental-feature links open Video. `SettingsRouter.route(toModelTab:open:)`
stages explicit tab navigation before opening the window.

## Model loading policy (2026-09-07)

Use one ordered **Automatic / On demand** list, not separate Default/Auto-load
settings. Service shows all scenes; each modality tab uses the same component.
Ready pool members are reused before cold ones, then saved priority decides.
Explicit scenario choices are exact and do not change membership. Download and
runtime state remain separate; unavailable saved entries are explicitly clearable.
Automatic loading can be paused without clearing the pool. App-launch startup
requires an automatic chat member as well as both startup switches; neither a
legacy default nor session history authorizes loading a manual model.

Preferences persist immediately. **Save** also acknowledges the policy on the
running API via authenticated `PUT /v1/service/model-policy`; no model or service
is restarted. Stopped services receive it at their next spawn. HTTP inference
with no ready pool member fails with 409 instead of downloading/loading another
model. Native tools use the existing approval UI for cold loads. Metadata-only
voice discovery can resolve an explicit cold alias without loading it.
See [selection and startup](../decisions/youzi-model-selection-and-startup.md)
for migration, ordering, API compatibility and audio/video limits.

## Generation-parameter defaults contract

- `ModelGenerationDefaults` reads persisted values at request time.
  `ModelGenerationSettings` exposes the same store to observable workspaces.
- A saved preference never overrides an explicit per-request selection.
- Image default remains 512 × 512. Presets are 512, 768, 1024, 1280, 1536 and
  2048 long-edge pixels; ratios 1:1, 3:4 and 4:3 remain multiples of 16.
- `ImageClient.generate` accepts omitted size and reads the shared default.
  Image edits deliberately do not gain a size parameter.
- `AudioClient.synthesize` accepts omitted voice/speed. Omitted voice is
  validated against the selected model's actual voices endpoint, falling back
  to its first voice. Empty voice lists fail rather than inventing a speaker.
- Audio preferences are keyed by model alias. Reading the settings page does
  not start a model. Reading voices for a stopped model requires confirmation.
- Existing image/audio workspaces follow updated defaults until that parameter
  receives a per-use override. These overrides do not alter global preferences.
- Video workspaces reconcile saved defaults against the active capability
  response. Unsupported size/duration falls back to the smallest supported
  choice; empty capabilities retain the non-submittable sentinel values.
- Default keys use the `youzi.models.*.v1` namespace. Existing sampling, model
  performance, auto-start, visibility and video opt-in keys are not migrated.
- Preferences persist immediately; the shared Save footer retains its existing
  flush/confirmation behavior. A valid port edit persists immediately; an
  invalid edit shows an error and does not replace the last valid port.

## Service boundary and limits

A blank preferred port preserves automatic allocation across 8000–8009. A saved
1024–65535 port is pinned, with an occupied-port error rather than silent fallback.
`RAPID_DESKTOP_PORT` remains the higher-priority test/process override. Port
changes apply on the next service start, never by interrupting current work.

This change does **not** expose an unauthenticated external API or disable the
private bearer on model-management endpoints. Optional public App Keys and LAN
binding still require a separate inference/admin authorization design. Local-only
optional inference authentication is described below. It also does not implement the
entire LLM multimodal tool dispatcher: native image/speech tools use the shared
pool and generation defaults; native video chat tools remain separate work.

Model context capacity is shown from the live profile when known. Maximum output
is an existing sampling limit, not a fabricated context-window setting.

## Verification

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac --filter \
  'ModelGenerationDefaultsTests|Image.*Tests|Audio.*Tests|Video.*Tests|Settings.*Tests|PortAllocatorTests|AccessibilityIdentifierInventoryTests'
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift build --package-path apps/rapid-mac -c release
git diff --check
```

Tests cover persisted defaults, invalid values, per-model voices, explicit
workspace overrides, request-body dimensions and speech values, video capability
fallbacks, port precedence, legacy links and the relocated accessibility hooks.

For a local package refresh, back up the current bundle before `scripts/build.sh`
(the script replaces it), retain the current sidecar, restore that sidecar after
`SKIP_SIDECAR=1` assembly, and re-sign/verify the complete app. Do not replace the
executable alone: Sparkle's embedded framework and rpath must remain valid.

## API access and voice preview (2026-09-05)

- Models → Service renders and copies a nonlocalized loopback base URL; ports
  such as 8000 are never grouped as `8,000`.
- “Copy current API Key” is available only after the service materializes a
  bearer. It copies the **active** key, not a pending rotated credential.
  Configure compatible clients with the base URL and this key. A direct browser
  navigation cannot attach a bearer header and returns 401 while key verification is enabled.
- The key grants local inference **and model-management access**. It is not a
  restricted external App Key. Loopback-only and required management auth remain
  unchanged; restricted external keys and LAN access are separate pending work.
- Key rotation policy now lives beside the API address, not under Tools. Keychain
  failures are shown; replacement keys apply only after a service restart.
  There is no plaintext display, URL credential, or secret-bearing example.
- Explicit key copy uses concealed/transient pasteboard markers. While the app
  remains running, it clears the copied revision after 60 seconds, never newer
  unrelated clipboard content. Other apps that read the clipboard cannot be
  prevented from retaining it; treat copies as sensitive.
- Models → Audio includes editable preview text (up to 500 characters), manual
  preview/replay, Stop and opt-in automatic preview on voice/model changes.
  Preview uses current speed and actual model voices. Loading a stopped model
  requires confirmation; opening settings never loads it.
- Rapid voice changes are debounced. Stop, text/speed changes and leaving the
  page cancel waiting/playback; late responses cannot play over a new voice.
  Server-side computation already submitted may still finish after cancellation.

## Live typography

- General → Font Size applies and persists on selection, without Save/restart.
  The separate sample block was removed; the actual application is the preview.
- The shared font ramp now observes the in-memory configuration instead of
  reading UserDefaults inside otherwise unobserved view bodies.
- Settled/streaming TextKit prose and code, plus the native composer, receive
  the same app scale. The composer is updated in place, preserving draft and
  selection; font updates defer during IME pre-edit. No page identity reset is
  used, so changing typography does not recreate task state.
- Ctrl+= / Ctrl+- changes one of four bounded steps; Ctrl+0 resets to Medium.

### Voice-lane regression guard

The first native preview smoke test found a false cancellation: after reading
voices, a ready chat process can route TTS, but the lazy voice engine has not yet
loaded. Never require `isModelResident(voiceAlias)` before the first synthesis.
Use `isVoiceLaneReady` for the authorized request, exact HF-path audio residency
for load-confirmation decisions, and refresh voice residency after success.
`SettingsVoicePreview.synthesizeOnReadyLane` is tested with a ready chat alias
and a nonresident voice alias. Normal `CancellationError` ends quietly.

## Compact service controls and local anonymous inference

- One Service card contains address, port, required-key toggle, masked active
  key, copy, and explicit random replacement. Startup controls are separate.
  There are no duplicate credential cards, curl examples or automatic-rotation
  picker. Existing installations migrate once to Keychain-backed manual rotation.
- Saving the required-key/anonymous-inference policy applies it live through the
  authenticated service endpoint without restarting models. Generating a new key
  is separate: it does not mutate the active session key until the next service
  start. Copying always returns the currently active key.
- Authentication defaults to required. Explicitly confirming the toggle off
  applies to the live service on Save and adds `YOUZI_ALLOW_ANONYMOUS_INFERENCE=1`
  to the next supervised child. Ambient environment cannot opt the desktop in.
- Anonymous exceptions require an actual loopback peer and loopback/localhost
  Host, no Origin or credential headers, and no cross-site Fetch Metadata.
  Forwarded headers are not trusted. An invalid supplied key still fails.
- The allowlist covers model listing, chat/completions/responses/messages,
  embeddings, speech/transcription/translation/music/voices, image generation
  and editing, video creation and job reads. `/v1/models/{id}` remains protected.
  Residency, load/unload, MCP configuration, cache and video deletion always
  retain bearer verification. Do not replace the allowlist with a `/v1` prefix.
- Image routes now consistently require the auth dependency. Video creation
  and image edits apply the same policy before body spooling; body limits remain.
- This is a local convenience mode, not multi-user isolation: other local
  applications can consume inference resources. Keep auth enabled if unwanted.

## Compact controls, file categories and tray

All native radio groups prefer a horizontal row, falling back to native vertical
layout when the window/font size cannot fit. Keyboard/AX semantics are retained.
Model Files always offers Chat / Audio / Image / Video, including empty catalogs;
Video defaults remain in their separate outer tab. Video cache state comes from
the runtime's machine-readable catalog. Loaded secondary models cannot be deleted
until stopped.

The single AppKit tray item is a template leaf branded Youzi. On menu open it
shows CPU/GPU/memory, resident chat/image/video models and deduplicated audio
lanes, plus Copy endpoint and Copy API Key. Probes run off-main and update every
2 seconds while open; CPU needs two samples, unavailable sensors show a dash.
The key is never included in menu labels and uses the same expiring concealed
clipboard helper as Settings. Model rows refresh on menu open.

## Simple-chat regression and proxy DNS

Completed empty assistant placeholders no longer render avatars. Structured
calls show the shared tool progress/result chip. Reasoning-only messages have a
collapsible reasoning block. Raw tool-call syntax in the tools-disabled final
round fails instead of counting as an answer; it is never executed beyond the
three-call budget. A render-only policy also recognizes older saved artifacts
following tool activity in the same user turn, without rewriting history.

The reported browse failures resolved public domains to the `198.18.0.0/15`
benchmark network. This is consistent with proxy Fake-IP DNS, not proof of a
specific proxy. The UI explains the rejection. Switch affected proxy DNS to
real-IP resolution; do not whitelist this range or disable SSRF checks.

### Local runtime delivery and health checks

The sidecar contains sourceless Python modules. Editing repository `.py` files
or installing only the Swift executable does not update the running API. Build
native + sidecar from the same reviewed commit, preserve package `__init__.py`,
and run candidate-only import/route checks from outside the repository. Verify
`codesign --verify --deep --strict`, resource sealing and framework paths before
installation. Do not modify a signed installed bundle in place.

Back up the complete app (and an active override if present), quit only its exact
process normally, and replace the full bundle. Rollback restores that full backup
and verifies its signature. Never reset preferences, keychain, tasks, files,
permissions or model caches. See the delivery runbook for health/rollback details.

Health checkpoints: app remains responsive after launch; `/health` responds;
unauthenticated `/v1/models` gives 401 in required mode; a valid active key lists
models; wrong keys and no-key admin calls fail. Independently test anonymous mode
with loopback TestClient peers, remote peers, hostile Host/Origin and preparse
media gates. Native QA checks the compact Service page, four file categories,
font selection without sample block, tray metrics, and persisted broken chat.
