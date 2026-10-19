# Atlas — Direct model loading and visible remote discovery

Owner: Atlas integration with Pixel UI, local Mac. Branch: fix/youzi-model-loading-direct.

Remove duplicate startup/global pool controls. Per-model Automatic/Manual is authoritative; support automatic or explicit media-only startup; keep manual inference resident-only. Preserve model selection, remote routing, capacity protection and explicit tool approval. Do not reset user preferences or credentials.

Remote discovery opens a searchable popover, displays counts and leaves selection explicit. No candidate for the selected workflow reveals all returned models. Existing credential scope/cancellation stays intact.

Verified: 134 tests / 11 suites before the final manual-inference regression addition; final integrated regression and native delivery remain to be recorded. Native-only change, packaged runtime can remain unchanged. Existing startup flags retained for rollback. Full bundle update; do not patch the running app.
