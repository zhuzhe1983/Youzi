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

Candidate packaging/GUI acceptance is in progress.
Use `RAPID_DESKTOP_NO_PORT_SWEEP=1` for all native tests/builds/launches. This is an
incremental native UI delivery: restore the complete verified, unchanged bundled
runtime from `candidate-4772994a`, then sign/verify the complete new app. It is not
a clean-room sidecar rebuild or multimodal inference acceptance.

Correction to the previous sidebar handoff: `candidate-4772994a` was subsequently
launched successfully after the desktop unlocked. The actual homepage was
verified. Its complete bundle is retained unchanged as rollback. Full sidebar
More/expand/scroll acceptance is not claimed here.

Next owner: Pixel for focused tests, package/resource verification and native
popover acceptance; Atlas for any later branch integration. Before switching,
verify idle/draft state and use normal Quit; never rebuild a running sibling
bundle. Do not change model files, credentials or runtime overrides.
