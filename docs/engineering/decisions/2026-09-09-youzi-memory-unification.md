# Unified memory: legacy compatibility and chat-first ingestion

Owner: Atlas, implementation and local verification on Local Mac. Pixel UI
boundary included in this task. `.agents/roles/` and Orca are absent; use a
separate Git worktree. Completion branch: `atlas/youzi-memory-finish-20260930`,
based on integration commit `f0ad132c`. This delivers the memory service and
Settings controls; it is not a public release or full FR-13 acceptance.

## Contract

- `YouziProductModel`/`YouziDomainStore` is the only live authority. `MemoryStore`
  remains an observable compatibility facade, not another JSON writer.
- Schema v4 adds optional legacy/context metadata, unknown node confidence and
  ingestion/deletion controls. v1/v2/v3 migrate explicitly; future versions fail
  closed. Never turn a decode error into an empty writable memory library.
- Legacy import preserves UUID/content/timestamps/evidence counts/conversation
  references. Import is atomic and idempotent. Legacy facts have unknown
  confidence, imported provenance and legacy-compatible context admission, NOT
  fabricated user confirmation. No model call is required for migration.
- Keep a private legacy rollback archive after commit, never dual-write. Explicit
  forgetting scrubs matching legacy originals/archives too; cleanup failures are
  surfaced and retried. Imported identity markers prevent re-import.
- Automatic collection remains opt-in using the existing preference. Only new,
  eligible user message text is analyzed; no historical, filesystem or connector
  scan, no implicit model load, no remote extraction. Speech participates only
  when its user transcript follows this chat path.
- A local, cancellable idle queue defers to foreground generation and voice.
  Candidates require exact message IDs and matching evidence excerpts. Model
  output may propose, never confirm or delete. Explicit user controls authorize
  manual addition, confirmation, correction and forgetting.
- Context is scope/validity/trust/budget bounded. User-confirmed and legacy-admitted
  records are distinct. No 80-node cap and no whole-graph prompt dump. Memory is
  quoted reference data, not an instruction channel.
- Forgetting removes nodes, incident edges and unreferenced citations; salted
  suppression fingerprints/message IDs prevent automatic reappearance. Explicit
  manual re-entry remains possible. No embeddings or derived summaries exist in
  this milestone, so there is no hidden secondary index to leave behind.
- Settings exposes manual addition, candidate confirmation, correction, forgetting,
  queue pause/retry and errors even while automatic collection is off. About Me
  continues to show confirmed domain nodes. The variant-C graph workbench remains
  a separate UI milestone; no graph redesign or file/connector/MCP ingestion is
  claimed here.
- Memory context is never attached to remote-model chat. A new opt-in or app launch
  only permits newly created messages; regeneration does not harvest old history.
- Source deletion commits suppression and removal together. A failed memory purge
  prevents the chat source from being deleted, preserving a retry path. Corrupt
  domain files keep their original bytes plus a recovery copy so later writes and
  fresh launches cannot silently replace them with an empty graph.

## Verification / rollback

Use isolated temporary domain/legacy stores and preference suites. Cover migration,
repeat launch, failed commit, unknown schema, provenance, confirmation, context
scope, correction, source deletion, suppression, facade parity and queue gates.
Every native test/build/launch uses `RAPID_DESKTOP_NO_PORT_SWEEP=1`. Do not mutate
running sibling bundles. Retain the delivered client as a rollback executable.
Schema-v4 data cannot be directly opened by the old client; never suggest running
both against the same store. A downgrade requires an explicit backed-up restore.

## Focused regression checks

Run in `apps/rapid-mac` with isolated temporary stores and no model requests:

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --filter 'MemoryStoreTests|MemoryExtractorTests|YouziMemoryServiceTests|YouziMemoryIngestionQueueTests|YouziDomainTests|YouziDomainMigrationTests'
```

The tests cover transactional import/write failure, schema 1/2/3 migration,
corrupt/future read-only behavior across restart, legacy provenance, evidence
validation, confirmation, scope/expiration/revocation/escaping/budget,
correction/forgetting suppression, source deletion, facade parity and opt-in
boundaries, queue capacity/cancellation/voice/pause/retry and eligible-job fairness.
No native app launch or production data is required. Recovery from a corrupt store
is an explicit backed-up replacement followed by restart; an error is never an
instruction to delete user data automatically.

An isolated pre-integration check is available from the repository root:

```sh
python3 apps/rapid-mac/scripts/test-memory-isolated.py
```

This compiles the real domain/store/lifecycle/product/memory sources and runs
52 tests in six suites (passed on 2026-09-30, arm64 macOS). It uses minimal seams
for unrelated chat history shapes and the completion URL builder, never a live
model or desktop app. The temporary package is removed after the run. It does
not certify SwiftUI, ChatViewModel or RapidApp integration; those remain covered
by the normal app build and focused integration tests above.
