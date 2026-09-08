# Chat output previews and image worker recovery

## Behavior

Simple and Professional chat show saved image, audio, video and HTML output
cards directly beneath their originating native tool calls. Cards appear as
soon as a successful tool receipt arrives, even if the assistant follow-up is
still streaming or the tool's JSON disclosure is collapsed. My Files remains
the authoritative library; previews do not duplicate file bytes.

- Images/video use bounded square thumbnails and the existing media overlay.
- Audio offers play/pause and stop without leaving the conversation.
- HTML offers an explicit Open File action; generated HTML is not executed in
  the chat renderer.
- Finder reveal uses managed file resolution, not model-supplied paths.
- Changing conversations or leaving the chat stops playback and releases leases.
- An unavailable file has a disabled card. An absent artifact record is not
  resurrected. Historical receipts can render without a schema migration.

The resolver accepts only successful native generation receipts with matching
call ID, artifact/file UUIDs, current task ownership and expected media kind.
Malformed receipts, error results, external tool output and untrusted paths
cannot create a preview. Raw backend errors are not stored in chat.

## Image thread ownership

A process-local lock serialized mflux work but did not guarantee load/render
thread affinity. Preloading and subsequent requests could land on distinct
`asyncio.to_thread` workers, producing `There is no Stream(gpu, ...) in current
thread` after a successful request.

`runtime.image_lane.ImageEngine` now has a lazy single-thread owner for loading,
rendering/PNG encoding and releasing its model. It does not borrow the primary
chat/audio worker. Progress/cancellation remain directly accessible. Accepted
jobs drain before owner cleanup, including canceled preloads and repeated
cancellation during stop. A stopped adapter must be replaced by a new load.
No public endpoint/schema, global stream monkeypatch, download policy or
cross-model unloading behavior was changed.

The client maps recognized image failures to allowlisted localized messages.
Do not automatically retry a GPU failure or fabricate a saved artifact. If an
old server still runs, install the corrected paired client/backend and reload
the image model; changing the prompt does not fix the stream ownership error.

## Verification

Run from the repository root, using a Python environment with the project test
and image dependencies already installed:

```sh
python -m pytest tests/test_image_worker_affinity.py tests/test_image_lane.py \
  tests/test_resident_models.py tests/test_server_load_model_order.py \
  tests/test_serve_image_gen_completeness.py tests/test_youzi_video_residency.py -q
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac \
  --filter 'YouziChatArtifactTests|YouziLocalModelToolsTests|YouziArtifact|YouziSimpleTranscript|ToolCallChip'
RAPID_DESKTOP_NO_PORT_SWEEP=1 YOUZI_CHAT_ARTIFACT_VISUAL_QA=1 \
  swift test --package-path apps/rapid-mac --filter visualChatArtifacts
```

The opt-in native fixture uses temporary domain/files/defaults, no real history
or model server. It writes pending/completed and narrow English screenshots
under the system temporary directory's `youzi-chat-artifact-visual-qa` folder.
It is a shared-component rendering check, not proof of a complete LLM roundtrip.

For real image acceptance, use only an already cached checkpoint and sufficient
physical free memory. Set `HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1`. Construct
one `ImageEngine("filipstrand/Z-Image-Turbo-mflux-4bit")`, preload it from one
caller thread, then submit `generate(prompt=..., width=512, height=512,
num_inference_steps=4, seed=42+i)` from three distinct single-thread caller
executors in sequence. Decode every result with Pillow, check PNG dimensions
and nonuniform pixels, then `await engine.stop()`. This checks ownership across
requests; it is not a speed benchmark or proof for all image families.

Before changing a running local candidate, check chat/image/video activity and
preserve the prior bundle for rollback. All native builds/tests/launches must
set `RAPID_DESKTOP_NO_PORT_SWEEP=1`. Never overwrite the running bundle or sweep
ports. Release/main integration is separate from local task-branch delivery.
