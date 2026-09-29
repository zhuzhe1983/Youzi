# Youzi September 2 historical prototypes

This archive preserves 66 previously uncommitted files from the September 2
prototype effort: 32 Swift implementation files, 25 Swift test files, eight skill
documents and one capability catalog. They contain 1,173,954 bytes. These are
historical design and implementation references, not active product features.

The files were copied from the immutable September 30 cleanup snapshot of
`Youzi-complete/.wip-stash`. Every file matches that snapshot byte for byte.
[manifest.json](manifest.json) records relative paths, intended changes, original
and archived SHA-256 checksums, source provenance and verification limits. No
credential or private endpoint required sanitization; synthetic redaction
fixtures and example URLs retain their original bytes. No raw Butler transcripts
or workstream reports are included.

The archive sits outside every Swift package source, test and resource target.
Nothing here is loaded, seeded, registered, built or shipped by the application.
Archived comments and test names describe the prototype's intended behavior;
they are not evidence that the current application delivers those behaviors.

## Why these prototypes remain archived

The current [unified memory contract](../../decisions/2026-09-09-youzi-memory-unification.md)
uses `YouziProductModel` / `YouziDomainStore` as its one live authority, with a
compatibility facade, explicit migrations, opt-in chat ingestion and suppression
after forgetting. The archived SQLite repository would introduce another
authority and needs a separate migration decision. Its Graph-C UI and file/MCP
ingestion interfaces are not part of the delivered memory milestone.

The current [live-voice contract](../../decisions/youzi-live-voice-streaming.md)
uses the existing `ChatViewModel.send` pipeline and bounded audio playback. The
archived voice IO, domain and orb assume another shared runner. Their proposed
session controller and session tests are absent from this set; copying these
files into the app would not yield a complete voice runtime.

| Area | Preserved work | Recovery boundary |
| --- | --- | --- |
| Memory | SQLite schema, FTS5 search, citations, categories, queue, service and Graph-C UI | Keep one persistence authority; decide migration, source permissions and deletion semantics before reuse. |
| Execution | Shared turn runner, scoped tool authorization, task preparation, execution and typed artifacts | Reconcile with current chat, tool approvals, cancellation and persistence; do not create a second runtime. |
| Capabilities | Repositories, package loader, MCP account reconciliation, credential adapter and catalog | Review account identity, grant invalidation and existing catalog IDs before registering anything. |
| Automation | Cron evaluation, repository, scheduler, notification adapter, editor and tests | Scheduling, persistent authority and app lifecycle composition require a separate feature contract. |
| UI | Capability center, memory workbench, automation page and voice orb | The archived capability center also declares `YouziSimpleHelpersPage`, already present in the active UI; reconcile the declaration and environment owners. |
| Voice | Privacy/VAD vocabulary, microphone/playback adapters and orb presentation | Reuse useful behavior only through the active voice owner; the prototype controller is missing. |

The resource catalog uses fixed IDs for eight helpers and eight skills. Current
in-code seeding derives IDs differently. Restoring it wholesale could duplicate
existing records or change their identity. The source and test set also depends
on historical app, domain and chat integration edits that are not captured here.

## Verify and recover selected work

From the repository root:

```sh
python3 docs/engineering/archive/2026-09-02-youzi-prototypes/verify.py
```

The verifier checks the exact file set, relative paths, absence of symlinks,
byte sizes, checksums and unchanged original/archive digests. It never imports or
executes the archived Swift code. All 57 archived Swift files also passed
`xcrun swiftc -frontend -parse` during preservation. No native build, runtime
test, model request, microphone action or production data migration is claimed.

To inspect one historical file without modifying the application:

```sh
git show HEAD:docs/engineering/archive/2026-09-02-youzi-prototypes/source/apps/rapid-mac/Sources/Rapid/YouziMemory/YouziMemoryRecords.swift
```

For reuse, start a new task branch from the current integration base, choose the
specific behavior to recover, and copy only the selected source and its relevant
tests from `source/`. Compare them with current owners and interfaces before
editing active paths. Keep the archive unchanged as the recovery reference.
Atlas owns compatibility and migration decisions. A feature must pass fresh
typechecking, focused tests and integration acceptance against the current app;
historical test names or syntax checks do not replace those gates.

The original worktree and external snapshot remain available until the cleanup
owner verifies inclusion of this archive in the intended remote branch. Removing
a worktree after that check does not remove these source files from Git history.
