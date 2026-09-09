# Optional remote model supplements

Date: 2026-09-09. Owner: Atlas, UI cross-cutting with Pixel. Host: local Mac.
Task: `atlas/youzi-remote-models`, based on `9de4666f` to retain the delivered
model-menu/sidebar UI. No backend, public API, release or memory-graph migration.

## Decision

- Keep local-first as the default. Add remote configurations at the bottom of
  existing model settings, not another prominent tab or downloaded-model row.
- A remote entry represents one provider model and workflow: chat, transcription,
  speech, image or video. Multiple entries may use the same server/model ID.
  ASR/TTS share an audio source-priority override but keep separate preferred
  remote entries. No guessed capabilities from model names or `/models`.
- Document v1 stores metadata and priorities in `youzi.models.remote.v1`.
  Opaque `youzi-remote/<UUID>` aliases avoid collisions with local catalogs.
  Keys are per-entry Keychain items in `com.youzi.remote-models.api-key.v1`,
  device-only and not synchronized. They are never serialized into metadata.
- Keep local download, residency and memory accounting unchanged. A remote
  alias is routable configuration, not verified health or a resident model.
  Remote requests never start/stop a sidecar or report model RAM consumption.
- Automatic selection takes the existing local resident-pool recommendation
  and the enabled preferred remote for the workflow, ordering them by priority.
  It may use the other source if the first has no candidate. Once selected,
  an alias is explicit; saving priority does not retarget existing choices.
  The model menu offers a one-shot "Choose by current priority" action.
- No cross-provider inference retry/failover: local-first does not mean trying
  local inference and disclosing the same prompt to a cloud provider on error.
  Explicit disabled/removed aliases fail visibly instead of silently falling
  back. Changing priorities does not unload local resident models.

## Transport and consent boundaries

App-side Swift clients implement the existing chat SSE/audio/image/video
workflows against configured API bases. Local wire behavior stays unchanged.
Remove local-only sampling/image/video fields on remote requests. Discovery
only reads `/models`; a successful list is not inference/capability validation.

API bases reject credentials, query/fragment, endpoint names and ambiguous path
segments. HTTPS is the default; HTTP requires an explicit per-entry opt-in,
including trusted LAN/loopback servers. Remote URLSession has no persistent
cache/cookies and refuses redirects. Local sidecar bearer credentials must
never be inherited by an anonymous remote request. Provider response bodies
and signed image URL errors are not included in user-facing remote errors.

Changing an API base, including a gateway path, requires an explicit new key
or an explicit empty key for both Save and Discovery. A metadata encoding error
must occur before Keychain mutation; a failed key write preserves old metadata.
Corrupt/newer configuration documents fail closed instead of overwriting data.

Chat freezes an endpoint/key for a complete tool loop. Remote turns do not
spawn automatic title/follow-up/memory-extraction inference. Prompt context,
existing memory, required attachments and authorized tool results may be sent
to the selected remote provider; the editor and source panel disclose this.
Existing tool approvals remain in force. Local model-management/multimodal
tools, Live Voice, and the public sidecar `/v1` API remain local-only: adding
providers must not silently grant new remote tool authority or billed work.

Image output accepts base64 or a provider URL. Provider URLs are untrusted,
not equivalent to user-configured bases: public HTTPS only, DNS validation and
IP pinning, credential-free/no redirects, 32 MiB maximum. LAN providers should
return base64. Remote image cancellation stops the client task, not necessarily
provider processing or billing.

Video presets are explicitly configured. The VM freezes endpoint/key and
cache namespace for a connected video session. Editing config does not redirect
active polling/content operations. Disable/removal blocks new submissions but
keeps the active session's model visible and pollable. Reconnect applies edits
only when no live active jobs/submission remain. Video deletion is a separate,
confirmed provider deletion, not cancellation or a refund. Local-only queued
cancellation and bounded tool-content helpers reject remote endpoints.

## Verification and limits

`RemoteModelTests` uses isolated preferences, fake credentials, and URLProtocol
fixtures: no paid provider requests or user Keychain reads. Coverage includes
routing by all five workflows, credential isolation/change rules, OpenAI-shaped
SSE/tools/audio/image/video requests, local-extension omission, single-dispatch
remote errors, private image URL rejection, video session pinning, and bilingual
native settings/editor snapshots. Existing client/model/selection/settings
regressions run alongside it; commands and results live in the operations doc.

Not universal provider compatibility. This is Chat Completions, not a Responses
API adapter or Realtime API. Providers with different auth, endpoints, reasoning
parameter requirements, voice names or presets need their own compatibility
work. The no-redirect policy is implemented, but the fixture suite does not
simulate real HTTP redirection. Provider generation and end-to-end GUI/network
acceptance remain separate from wire fixtures and synthetic native rendering.
