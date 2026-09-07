# Unified model selection and startup

## Product contract

Three independent concepts share one compact model list, not three competing
sets of preferences:

- **Default** (star): preferred downloaded model for a new chat or a workspace
  without a valid explicit selection. It does not load a model or authorize a tool.
- **Auto-load** (checkbox): membership of the next chat-service startup list.
  The global restore toggle controls automatic execution. Editing saves the
  choice immediately, without starting or unloading anything.
- **Ready** (status): observed backend state, never inferred from either choice.
  Video readiness may be lazy service registration, not permanent GPU residency.

The Service tab is the cross-scenario overview. Chat, Audio, Image and Video
reuse the same component filtered to their scenario; each retains its own
inference parameters. Audio distinguishes transcription and speech. Only
compatible downloaded models can be selected. Missing saved selections remain
visible and explicitly clearable, rather than silently lost.

“Load startup list now” runs the entire saved list after the chat service is
ready, even when automatic restore is disabled. App-launch loading additionally
requires the existing chat auto-start switch. It is not a separate daemon mode.

## Settings inventory / ownership

| Surface | Responsibility |
| --- | --- |
| Model Service | Port, authentication, API service, cross-scenario default/startup overview |
| Model Files | Storage, download, import and deletion; no competing default choices |
| Chat / Audio / Image / Video | Shared default/startup list + scenario-specific generation parameters |
| Chat scenario quick picker | Temporary selection/loading; check = ready, star = default; does not mutate startup/default choices |
| Audio voice audition | Selects the audition/current speech workspace model; explicitly not the global default |
| Dictation | Retains its existing explicit dictation-model override; not overwritten by speech/transcription defaults |
| Tray / status menu | Observed model/service state, not startup intent |
| Native local model tools | Discovery exposes `default_for`; prompts prefer defaults absent an explicit request; existing consent gates remain |

Existing valid workspace selections are not overwritten when defaults change.
Defaults do not change the public API's omitted-model behavior. Generation
parameters (voice, size, MTP, context) remain separate from model identity.

## Runtime and compatibility

Startup lists allow multiple chat, image and video models. Speech and
transcription each still own one engine cache: the UI and backend reject a
second occupied same-lane model rather than claiming unsupported multi-audio
residency. Process-scoped speculative decoding cannot be silently dropped when
admitting a secondary LLM; that model must start as primary or opt out of MTP.

Residency responses advertise `supports_preserve_loaded`. Desktop startup and
quick-picker loads require this capability and send strict Boolean
`preserve_loaded: true`. Existing clients omit it and retain prior behavior.
Preserving loads:

- bypass implicit same-kind image/video replacement;
- pin startup selections and omit `replace_group`;
- fail configured-capacity admission rather than evict siblings;
- roll back only the incoming model if measured memory overruns admission;
- reject replacement/reload flags combined with preservation;
- guard audio lane occupancy inside the backend's existing lane lock;
- check actual ready status after load, not only HTTP success.

Desktop workspace co-loads also request preservation on a capable runtime when
not explicitly replacing a group. No legacy stop/restart fallback is allowed
for startup-list loading. Explicit replacement flows remain explicit.

## Preferences and rollback

`youzi.models.startup.<slot>.v2` stores deduplicated alias arrays. Missing v2
falls back to legacy `youzi.models.residentService.<slot>.v1`; explicit empty v2
wins. Legacy values are retained for rollback. Defaults live separately under
`youzi.models.default.<slot>.v1`. Slots: chat, transcription, speech, image,
video. The prior global enable key remains unchanged.

Rolling back the client/runtime restores legacy single-selection behavior;
v2 choices remain in preferences for forward recovery. Do not delete user
preferences, model caches, tasks, or files during installation/rollback.

## Verification

Run with `RAPID_DESKTOP_NO_PORT_SWEEP=1` on macOS:

- Swift preference/migration, transport/capability, residency, scenario picker,
  session restore, settings routing/accessibility and local tools suites.
- Swift launch-media, audio, image and video suites.
- Python `test_youzi_startup_models`, `test_youzi_audio_preload`,
  `test_youzi_video_residency`, `test_residency_load_field_names`,
  `test_resident_models`.
- Opt-in `YOUZI_MODEL_SELECTION_VISUAL_QA=1` / Swift
  `YouziModelSelectionVisualTests`: synthetic shared-list renders using isolated
  preferences, not personal model/settings data.

Hardware multi-model inference and interactive installed-client acceptance are
separate checks; passing mocks/rendering is not proof of those. Native video
chat tools are a separate pending task, not included in this settings change.
