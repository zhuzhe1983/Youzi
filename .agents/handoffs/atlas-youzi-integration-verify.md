# Atlas integration verification handoff

Receiver: Atlas for main integration; Vector for baseline numeric failures;
Harbor for subsequent CI/package checks. Host: Local Mac.
Branch: `atlas/youzi-integration-verify-20260915`.
Report: `docs/engineering/operations/2026-09-15-youzi-integration-verification.md`.

## Verified facts

- `main@8137ae0f` is an ancestor of `pixel/youzi-composer-model-controls@2a31f692`.
  Its 31 product commits and the unique `3da34caf` voice-measurement commit merge
  without content conflicts in the isolated task worktree.
- Release native code compiles. The independent voice probe and existing
  candidate's resource checks pass. This does not constitute release acceptance.
- Python focused regression after repairs: 308 passed. Broad regression:
  3779 passed, 3 failed, 24 skipped, 11 deselected. The missing-mflux failure
  passes using the existing app's full dependency runtime. Two numerical
  comparisons and an additional isolated audio-health regression also fail on main.
- This integration repairs the stale residency-response assertion, 16 lint
  issues, the Golden chat fixture's missing language environment, and the video
  test's wait for asynchronous preview completion. Assertions are retained.
- Native final Release regression: 736 tests / 95 suites passed, including the
  corrected restored-conversation and video polling tests.

## Risks and next action

Review the final native result and the recorded baseline failures before deciding
main integration. A full-suite pass is not claimed for Python. Resolve the
order-sensitive audio-health baseline independently; do not remove its assertion.
The two numerical failures need investigation with the pinned MLX environment,
not tolerance relaxation justified only by the integration run.

No release/deployment, installed-client replacement, user-data migration, or
real audio/remote-provider generation was performed. Dirty memory/UI/video-tool
work remains in its original worktrees and must not be swept into this merge.
All cleanup done earlier in this session applied only to the eight worktrees
already represented in main; their branches were retained.
