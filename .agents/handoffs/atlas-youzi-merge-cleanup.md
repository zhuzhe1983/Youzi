# Youzi source integration and worktree retirement

Owner / receiver: Atlas; Local Mac. Integration branch:
`atlas/youzi-merge-cleanup-20260930`, starting main `8137ae0f`.
The user authorized resolving unfinished work, integrating it and recoverably
retiring the completed worktrees. Role files and Orca were absent.

## Verified result

All original local branch tips are included. Unified schema-v4 memory migration,
transaction/error recovery, candidate confirmation, bounded context and local
opt-in queue are complete, with remote memory exclusion and late-result
cancellation preserved. UI's original dirty patch is identical to the already
merged source; video diagnostics and positioning history are included.

Baseline numerical/audio-fixture failures, Swift 6.4 tuple compilation, WMO
fixed-video-size validation crash, golden-test registration-default leakage and
the source sidecar SciPy I/O trim omission were resolved. Assertions and numeric
tolerances are retained. Final native Release: 62 + 736 = 798 pass, exit zero.
Final Python audit: 3800 pass, 10 skip, 11 deselected, exit zero. Repository Ruff
lint/format, workflow pins/expressions, architecture generation and version sync
pass. The 19 formatting changes preserve exact parsed Python ASTs/constants.

All 66 unique old prototype files are stored exactly outside application targets.
Their SQLite/automation/capability/voice alternatives are historical source,
not activated features. Original dirty files, untracked files, ignored output
and task records remain recoverable through immutable snapshots and whole-directory
system Trash. Branch references are preserved.

## Integration and recovery contract

The source report and cleanup/recovery procedure are in
`docs/engineering/operations/2026-09-30-youzi-integration-cleanup.md`.
Fresh independent acceptance is required before fast-forwarding/pushing main;
the final verdict, source SHA, test proofs and exact cleanup manifest are retained
outside the retired worktree. Cleanup rechecks inclusion, files and process/task
use, then backs up each Git registration and moves only enumerated task
directories via the system Trash API. Two safety backups and the visualizations
directory are ordinary artifacts and stay in place.

## Future distribution work

Atlas / Harbor own the next separately authorized distribution: rebuild the
sidecar with retained SciPy I/O, package/sign and run live acceptance. No installed
app replacement, release, model-weight inference or production data migration
was performed by this source task. A schema-v4 store cannot be silently read by
older schema writers; downgrade requires restoring a compatible backed-up store.
Use the integration report's recorded source checks and the local recovery
manifest for reproducible verification and rollback. No source-completion
blocker remains after the final passing runs.
