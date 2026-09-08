# Pixel -> Atlas / Harbor: scenario picker vertical order

Owner: Pixel, local Mac. Branch: `pixel/youzi-model-menu-order`, based on
`5f791825` from the delivered sidebar branch. The configured role files and Orca
are absent; this task uses a separate Git worktree. No main merge or public
release is part of this task.

## Scope

Move the scenario toolbar and downloaded-model list above the memory bar and
available-memory label. Keep memory/refresh outside the scrollable model list.
Preserve model filtering/loading, settings routing, accessibility identifiers,
font sizing, memory calculations and the preceding sidebar/media work.

Add a source-order regression assertion and a bilingual native layout fixture
with model rows above the memory footer. No backend/build-sidecar inputs differ
from sidebar code commit `4772994a`.

## Verification and delivery

17 scoped Swift tests / three suites passed, including opt-in native layout
fixtures (Chinese/English and toolbar font sizes). Command:

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 YOUZI_MODEL_TABLE_RENDER=1 \
  swift test --package-path apps/rapid-mac \
  --filter 'YouziModelTable|YouziScenario|YouziModelOccupancy'
```

Candidate packaging and focused native GUI acceptance are complete.
Use `RAPID_DESKTOP_NO_PORT_SWEEP=1` for all native tests/builds/launches. This is an
incremental native UI delivery: restore the complete verified, unchanged bundled
runtime from `candidate-4772994a`, then sign/verify the complete new app. It is not
a clean-room sidecar rebuild or multimodal inference acceptance.

Correction to the previous sidebar handoff: `candidate-4772994a` was subsequently
launched successfully after the desktop unlocked. The actual homepage was
verified. Its complete bundle is retained unchanged as rollback. Full sidebar
More/expand/scroll acceptance is not claimed here.

## Delivered candidate

Code commit: `6e5aac94`; local identity: `candidate-6e5aac94`.
App in this task worktree: `apps/rapid-mac/build/Rapid-MLX Desktop.app`.
Release native build completed with `SKIP_SIDECAR=1`, then the unchanged runtime
was copied from the verified sidebar bundle; recursive content comparison passed
before signing. Complete app deep/strict signature verification, resource
verification (localization, assets, math fonts, Mermaid) and bundled engine
`--version` (`rapid-mlx 0.14.4`) all passed.

The idle old client had an empty draft and no port-8000 listener. It quit normally;
the exact new candidate launched with the no-port-sweep environment. Native AX and
screenshot confirm scenario tabs/settings at top, downloaded model rows in the
middle, memory bar/available-memory/refresh at bottom. Switched Chat -> Video and
verified the same two downloaded video entries and their size labels. Left this
popover and client open for user inspection; did not start/download/delete models
or change credentials/runtime overrides.

Task code and verification notes are pushed to this task branch. Next owner:
Atlas only if later integration is requested. No task-specific work remains;
main/release integration and full sidebar interaction acceptance remain separate.
Rollback: normal Quit and reopen the retained complete sidebar candidate with
`RAPID_DESKTOP_NO_PORT_SWEEP=1`; no bundle was overwritten.
