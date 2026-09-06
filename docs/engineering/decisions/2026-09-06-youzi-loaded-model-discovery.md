# Youzi model discovery: loaded models, additive metadata

- Date: 2026-09-06
- Owner: Atlas (API/integration), Local Mac
- Status: accepted for the current local application branch

## Decision

`GET /v1/models` retains the existing `ModelsResponse` / `ModelInfo` contract.
The earlier proposal to reduce the response to four model fields and move
metadata to a new `/v1/models/metadata` endpoint is superseded. No separate
metadata endpoint is introduced.

- Preserve OpenAI's `object: "list"` and `data` array. Each model includes
  `id`, `object: "model"`, integer `created`, and `owned_by`.
- Preserve additive context limits, sampling defaults, parser fields,
  capabilities/modality, serving-lane information, and speculative-decoding
  metadata. Explicit null parser values remain distinct from missing fields.
- Keep the existing additive top-level `models` catalog for Codex; include
  only returned entries with the `text` capability.
- Advertise only loaded engines and their routable canonical IDs/aliases.
  Configured-only, downloading, lazy/unloaded, loading, and evicting engines
  are excluded. A dedicated embedding engine requires `is_loaded == True`;
  a configured embedding name is insufficient.
- During startup (`ready == False`) or draining, both arrays are empty.
- Filter before building model cards. Discovery must not load a model or
  record an engine-access event.
- List and retrieve use the same service-lifetime `created` timestamp and
  `owned_by: "youzi"`. This timestamp is discovery identity, not the training
  date or checkpoint creation time.
- Keep `/v1/models/{id}` profile lookup behavior for desktop initialization;
  its lookup availability is not narrowed to the discovery list.
- Authentication policy is unchanged by this decision. The independent
  live-save/anonymous-inference work is not part of this API commit.

## Why retain the fields?

`vllm_mlx/agents/adapter.py` calls the original list URL to select the running
model and read context-window/reasoning support. Stripping fields silently
reduces this functionality. Desktop `ServerProfileFetcher` uses the single
model URL for richer sampling/context/parser metadata. Model catalog and
residency/load operations use separate internal paths. Codex also consumes
the additive top-level catalog.

The simple-chat context ring currently uses a local estimate rather than the
server's actual context limit; restoring discovery fields does not change
that preexisting UI behavior. Agent adapter bearer propagation is also a
separate preexisting limitation; anonymous adapter tests do not prove its
integration with a key-required service.

## Verification

`tests/test_youzi_loaded_models.py` covers lifecycle filtering, aliases,
loaded embeddings, configured bearer enforcement, consistent list/retrieve
identity, actual audio/image/video profile resolution, Codex filtering, and
the existing Agent adapter parsing a real ASGI response through its original
URL. It also exercises official OpenAI SDK list/retrieve parsing with strict
response validation and an HTTPX transport connected to the route under test.
Engine state in these tests is stubbed; they do not claim to load all model
weights or prove arbitrary third-party clients compatible.

Run the focused suite with `python -m pytest -q tests/test_youzi_loaded_models.py`.
The optional official-SDK test requires `openai` in the test environment;
keep it out of application runtime dependencies if only testing discovery.
Existing model, capability, residency, Responses, Agent, and audio route
regressions must also pass. Capability-test fixtures now explicitly represent
loaded engines instead of treating a configured model name as loaded.

### Recorded clean-commit result

On 2026-09-06, commit `b4ea91bd` passed **1480 tests, 14 skipped** in a clean
worktree, independent of the uncommitted UI/settings/auth batch. Environment:
macOS arm64, Python 3.12.13, pytest 9.1.1, official OpenAI SDK 3.8.0 available
only in the test process. Source import location was checked before running:

```sh
python -m pytest -q tests/test_*models*.py tests/test_resident*.py \
  tests/test_residency*.py tests/test_responses*.py tests/test_agent*.py \
  tests/test_audio*.py tests/test_routes.py tests/test_capabilities_field.py \
  tests/test_model_card_client_contract.py tests/test_http_auth.py \
  tests/test_embeddings_extra_guard.py
```

The recorded runner deduplicated expanded paths before passing them to pytest.
This is a correctness result, not an inference benchmark or installed-runtime
verification.

## Delivery and rollback

This change is scoped to the model routes, their regression fixtures, and
this decision. Existing local UI/settings work and remote integration remain
separate. The installed desktop uses a packaged Python runtime; editing the
source does not hot-reload it. Package and restart through the established
local delivery process before reporting live deployment. No release or
remote-main merge is authorized by this decision.

If discovery causes a compatibility regression after deployment, restore the
previous verified application/runtime as a unit. Do not erase the user's
working tree or remove the metadata fields as a workaround.
