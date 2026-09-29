# Unified memory completion

Owner: Atlas. Host: Local Mac. Receiving role: Atlas integration, with Pixel for
future About Me workbench. Branch: `atlas/youzi-memory-finish-20260930`, based on
`f0ad132c`. Original dirty `Youzi-memory-unification` worktree was never edited.
Input was the immutable snapshot recorded by the merge-cleanup Butler run.
Role files and Orca are absent in this checkout; the repository AGENTS.md applied.

## Delivered behavior

- `MemoryStore` is an observable facade over the app-owned `YouziProductModel`.
  Schema v4 imports legacy facts atomically and idempotently, preserving IDs,
  timestamps, evidence counts and source references without fabricated confidence
  or confirmation. Original legacy JSON is archived privately only after commit.
- New automatic collection is opt-in, local, resident-model-only and limited to
  newly authored user messages. Candidates need a matching message ID and exact
  quote. Confirmation is required for new prompt use. Remote-model chat does not
  receive memory context; imported compatibility admission remains distinct.
- Retrieval bounds scope, time validity, authorization, count and encoded prompt
  size. Context quotes and escapes memory as reference data. No legacy 80-item
  truncation, history scan, remote extraction, implicit model load, embeddings or
  hidden secondary index.
- Explicit correction/forgetting removes stale evidence and edges, scrubs legacy
  archives and persists salted suppression. Clear-all cutoff and source deletion
  controls commit with graph changes. Failed memory cleanup preserves the chat
  source and surfaces an error for retry.
- Corrupt storage keeps the original file plus a recovery copy, and remains
  unwritable across repeat calls and restarts. Future schemas stay untouched.
  This fixes the former move-aside behavior that could recreate an empty store.
- The queue has capacity and retry bounds, duplicate suppression, pause and voice
  gates, foreground cancellation, late-result protection, media-lane interruption,
  and eligibility selection that avoids an unavailable model blocking other jobs.
- Settings has manual add, explicit confirmation, correction, forgetting, errors
  and pause/retry. Entries remain manageable when automatic collection is off.
  About Me continues to display confirmed nodes; a graph-workbench redesign is
  outside this completion, as are connector/file ingestion and production rollout.

## Verified facts

`python3 apps/rapid-mac/scripts/test-memory-isolated.py` passed **52 tests in six
suites**. It compiles real production domain, migration, store, lifecycle, product,
memory service, facade, extractor and queue sources. Only unrelated chat history
shapes and the HTTP URL builder have minimal seams; no transport/model is called.
The script removes its temporary package on completion. Regression coverage:

- Schema 1/2/3 migration, atomic failed writes, corrupt and future schema retention.
- Legacy archive/provenance/idempotence, candidate evidence and confirmation.
- Scope, expiration, revocation, escaped delimiters and bounded prompt context.
- Corrections, forgetting suppression, source deletion, atomic clear-all cutoff.
- Facade parity, opt-in/session boundaries, retention beyond 80 entries.
- Queue bounds, eligible-job fairness, cancellation, voice/pause, media interruption
  and bounded retry, including a transport that completes after cancellation.

Environment: macOS 27.0 (26A428), arm64; Apple Swift 6.4
(swiftlang-6.4.0.34.1). Changed Swift sources also passed frontend parsing and
`git diff --check`. No app, model or production service was launched. No real
user storage or preferences were opened by the test fixtures.

## Integration gate and next action

No full desktop build was started: the parent owns the shared native build lane.
The isolated suite does **not** certify SwiftUI/ChatViewModel/RapidApp integration.
After merging this commit, run from `apps/rapid-mac`:

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --filter 'MemoryStoreTests|MemoryExtractorTests|YouziMemoryServiceTests|YouziMemoryIngestionQueueTests|YouziDomainTests|YouziDomainMigrationTests|MessageTreeTests'
```

Then review the Settings manual/confirm/edit/delete path and deletion failure
presentation in the isolated app verification environment, using no production
memory files. Parent owns push, final integration, independent acceptance and
recoverable worktree cleanup. Keep the original dirty worktree and immutable
snapshot until merge inclusion and all remaining work are accounted for.

Risk: schema v4 is not readable by the old client. Downgrade requires an explicit
backed-up restore, never parallel old/new clients against the same domain store.
Corrupt-store recovery likewise requires a backed-up replacement and restart.
