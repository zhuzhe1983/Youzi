# Preserve historical prototypes without activating parallel architectures

Date: 2026-09-30. Owner: Atlas integration. Status: accepted preservation decision.

## Context

Worktree cleanup found 66 unique, uncommitted prototype files from the September 2
effort. They were absent from the integration tree and available Git objects.
Discarding them would lose implementation work; adding them to active targets
would introduce unfinished execution, memory and voice alternatives during a
cleanup task.

## Decision

Preserve all files exactly under
[`docs/engineering/archive/2026-09-02-youzi-prototypes`](../archive/2026-09-02-youzi-prototypes/README.md),
with SHA-256 provenance and a verifier. Distill the architectural boundaries and
recovery procedure, and exclude raw agent transcripts. The archive adds no app
target, resource registration, feature switch, service or data migration.

The delivered JSON-backed memory authority remains governed by the
[memory-unification decision](2026-09-09-youzi-memory-unification.md). The active
chat and voice owners remain governed by the
[live-voice decision](youzi-live-voice-streaming.md). Recovering selected prototype
behavior requires a separately scoped feature, current-interface reconciliation
and fresh acceptance. Archive presence is preservation, not feature delivery.

## Evidence and consequences

All 66 files match the immutable cleanup snapshot: 1,173,954 bytes, 57 syntactically
valid Swift files and nine declarative resources. Review found no actual
credentials, private service endpoints or machine-specific secrets; synthetic
negative fixtures retain their bytes. All archived paths are relative and no
symlinks are included. Native compatibility and runtime behavior are unverified.

The original directories can be retired only after the cleanup owner verifies
this archive's inclusion in the intended remote branch and the normal worktree
safety checks. Future work can recover selected files from Git without requiring
the original machine or enabling a competing product architecture.
