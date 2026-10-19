# Atlas — Direct model loading and visible remote discovery

Owner: Atlas integration with Pixel UI, local Mac. Branch: fix/youzi-model-loading-direct.

Remove duplicate startup/global pool controls. Per-model Automatic/Manual is authoritative; support automatic or explicit media-only startup; keep manual inference resident-only. Preserve model selection, remote routing, capacity protection and explicit tool approval. Do not reset user preferences or credentials.

Remote discovery opens a searchable popover, displays counts and leaves selection explicit. No candidate for the selected workflow reveals all returned models. Existing credential scope/cancellation stays intact.

Verified: final integrated regression, 467 tests / 65 suites. Installed preview starts the configured local models; local Qwen Image is ready. Native UI has no duplicate preferred-pool controls. Gateway /models discovery opened the candidate popover automatically (100 models / 10 image candidates); selecting a candidate filled both names, then the unsaved form was cancelled. Local OpenAI SDK model list, streaming/nonstreaming Responses and authentication checks passed. Native-only change, packaged runtime can remain unchanged. Existing startup flags retained for rollback. Full bundle update; do not patch the running app.
