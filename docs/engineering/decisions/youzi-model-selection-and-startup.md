# Youzi model loading policy and scenario selection

Updated: 2026-10-19. Supersedes the separate **Default / Auto-load** design.
Owner: integration; native settings and sidecar routing must ship together.

## Product contract

A model has independent download, loading-policy and runtime states:

1. **Not downloaded**: offered by Model Files, never selected for auto-load.
2. **Downloaded / automatic**: belongs to a scene's ordered preferred pool.
3. **Downloaded / manual**: loads through an explicit Load action, not an inference request.
4. **Ready / busy / stopped / failed**: observed runtime state, not a preference.

“Default” and “recommended” describe a scenario's selection, not a second model
classification, residency list, or permission to load another checkpoint. The
preferred pool is the basis for future recommendations/performance work. Merely
recommending a model must not enroll, download or load it.

For an unspecified model, use compatible downloaded pool members, ready ones
first, then saved priority. An explicit model is exact: no fallback to another
model when it is missing, incompatible, cold or misspelled. An empty pool is a
real empty selection, not permission to resurrect a legacy default.

## Settings and launch

Settings → Models now has three children: **Model files**, **Model loading**,
and **Model service**, in that order. Model files shows measured or explicitly
estimated file size immediately beside the model name. Model loading owns the
Chat / Audio / Image / Video tabs, local loading policies, startup preferences,
and visible remote alternatives. Audio has separate transcription and speech lanes.
Legacy file/performance/video/service deep links keep reaching their corresponding
new page; old persisted service/files tab values normalize to Chat in Model loading.

Remote configurations default their editable local display name to the provider
model ID. A custom name survives provider-ID changes; requests still use the
provider ID and the configuration retains its stable UUID. Enabled configurations
appear in the matching workspace picker. Remote priority is selection priority,
not retry/failover: a failed generation is never sent to another service.

Model service contains only the loopback address, port, authentication and a
read-only snapshot of the actual `/v1/models` response (refreshed every five seconds
while visible). It has no model selectors, startup pool or remote configuration.
Only loaded local models are exposed. Loading, registered, evicting and remote
models do not become advertised just because they have saved settings. Errors
clear the displayed snapshot rather than claiming stale models are still available.
The API remains loaded-only; this UI change does not alter Python routing.
Each downloaded row exposes **Automatic / Manual**. Automatic members show
priority; promoting one reorders the same list rather than creating a default.
The quick picker shows a bolt for membership and a check for actual readiness.
Missing saved entries remain visible and explicitly removable.

Each model's loading policy is the only startup switch. The former global
“Load preferred pool on startup”, “Load pool now” and chat auto-start controls
are removed. Their persisted keys remain for rollback but no longer gate launch.
The first compatible downloaded automatic model owns the service; an image,
audio or video model can start without an automatic chat model. Remaining
automatic models load sequentially while preserving siblings.

An explicit Load action works in settings or the composer picker, including a
media-only cold start. Inference in chat/image/video/audio does not implicitly
load a manual model. Already-loaded manual models remain usable. Native model
tools retain their explicit interactive approval before loading. Capacity and
occupied audio-lane refusals remain visible; no silent replacement or download.
Changing policy saves intent immediately without unloading existing models;
it takes effect on next launch. API routing sync still uses Settings Save.

Remote discovery automatically opens a searchable list after a successful
non-empty response. No model is silently selected. The result shows total and
workflow candidate counts; if no workflow matches, all models are shown.
Selecting a row fills the provider ID and follows the existing display-name
rule. Endpoint/credential changes cancel and clear stale discovery.

Existing valid workspace/task model selections remain explicit overrides. A
media workspace may show an initial catalog recommendation when no pool member
is available; generating with that visible selection remains exact and does not enroll the
model. A manual model must first be loaded. New chat
without a usable pool requires selection instead of redirecting to initialization.
Voice/size/context/MTP defaults remain separate generation parameters.

## Native tools and API

Native image/speech tools accept an omitted model and use the pool. A cold
selected model requires the existing interactive approval before loading. Denial
is remembered for the turn; malformed arguments do not prompt. Tools never
silently download models. Discovery exposes `loading_policy`, `automatic_for`,
and `preferred_for`; `default_for` remains a compatibility alias derived from
`preferred_for`, not another persisted default.

The supervised sidecar receives `YOUZI_AUTOMATIC_MODEL_POOL` containing
`{"automatic":{"chat":["alias"],"speech":[],...}}`. Ambient environment cannot
replace the desktop-owned value. An invalid supplied value fails closed. No
value at all preserves standalone CLI behavior; this is distinct from an empty
policy. Native settings persist immediately. Model Settings **Save** also sends
an authenticated `PUT /v1/service/model-policy`, validates the echoed value, and
checks that the service session and preferences did not change during the await.
A rejected/stale update is reported as failed, not saved successfully. A stopped
service is not started; its next spawn receives the saved policy.

Chat Completions, legacy Completions, Responses, Anthropic Messages/count_tokens,
image/video generation, TTS and transcription use the same pool. Existing protocol schemas remain intact (chat callers use their
required `model` field; `"default"` is the existing automatic sentinel). Explicit
empty chat/Responses model fields remain invalid. Responses and Anthropic JSON/SSE report
the selected model rather than the process's boot primary; token counting uses the
same selected tokenizer. Standalone CLI keeps its existing compatibility aliases.

HTTP inference cannot display GUI consent. Under desktop policy, an unavailable
preferred model produces HTTP 409 / `automatic_model_not_ready`; an explicit cold
or wrong-scene model produces 409 / `model_not_ready`. Load it first with native
approval or the authenticated load endpoint. Routing does not itself load weights.
Do not convert these errors into a download or arbitrary model fallback. Voice
metadata permits explicit cold-model queries, but an omitted voice-list model
follows the ready preferred speech pool. Busy audio remains eligible; queued
speech/ASR checks readiness again inside the lane lock before inference so it
cannot reload a model retired while waiting.

Policy updates always require management authentication, including when loopback
inference is anonymous. They do not rotate keys, restart service, mutate the
registry or grant model-loading permission. Alignment/music are not new pool
scenes and retain their separate existing explicit routing. Standalone CLI
servers without desktop policy retain their legacy routing/default behavior.

## Residency limits and migration

Multiple chat/image/video services are supported subject to capacity. STT and TTS
still each have one runtime lane. Selecting a new automatic audio model changes
intent only; a preserving load will refuse to replace an occupied same-lane
model. It does not claim unsupported multiple-TTS or multiple-STT residency.
Video readiness may mean lazy service registration, not permanently allocated
GPU weights. Simultaneous readiness is not unlimited concurrent GPU throughput.

`youzi.models.startup.<scene>.v2` remains the ordered alias array. Absent v2 falls
back to legacy `youzi.models.residentService.<scene>.v1`; explicitly empty v2 wins.
`youzi.models.default.<scene>.v1` is retained only for rollback and no longer read
for routing. Legacy global enable keys are retained but ignored by the new startup policy. No automatic migration
adds independent defaults/history/recommendations to the pool. Existing users
with only a legacy default must explicitly choose automatic membership or select
a model for the current scenario.

Roll out a full native + sidecar bundle together. Back up/restore the complete
app; do not patch signed installed files in place. No preferences, keychains,
chat/task data, permissions or model caches should be reset. Older clients may
read retained legacy values again, but v2 remains for forward recovery.

## Verification and remaining boundaries

Use `RAPID_DESKTOP_NO_PORT_SWEEP=1` for every native build/test/probe/launch.
Regression coverage includes ordered/empty pools, exact requests, direct per-model startup,
legacy defaults ignored, approval denial, ready reuse, live authenticated Save,
spawn ownership, audio queue races, standalone compatibility and Responses model
metadata. Visual QA is synthetic, uses isolated preferences, and requires actual
inspection of the rendered Chinese/English images.

Routing mocks, offline audio callback tests and rendered UI are not physical
full-duplex or multi-model inference acceptance. Native video chat generation is
implemented in the follow-up [conversation video tools](youzi-conversation-video-tools.md),
with bounded owned-job polling and captured-task MP4 persistence. Synthetic tool
tests are not proof of real LLM tool selection or video generation/playback.
Full-duplex AEC requires attended speaker/microphone validation; ASR is still
utterance/window-based, not fully incremental recognition.

### Video workspace capability boundary

The workspace must send its exact selected alias to `GET /v1/videos/capabilities`.
An omitted query uses the automatic pool and is **not** appropriate for an
explicit on-demand selection. A resident auxiliary video engine is usable while
chat remains the process-owning model; readiness must check catalog identity
(alias or repository path) and a ready/busy runtime state, not compare the video
alias with the primary chat alias. Loading/failed/evicting entries are not ready.

Controls refresh when the selected alias, readiness or sidecar session changes,
not on every memory sample. Capability/history/preview results are scoped to the
sidecar epoch as well as alias/port/bearer: a persistent key on the same port does
not make a response from a retired process current. Requests never enroll an
on-demand model in the automatic pool or replace the chat engine.
