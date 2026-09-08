# Youzi Simple sidebar viewport and welcome layout

Owner: Pixel (local Mac). Task branch: `pixel/youzi-sidebar-layout`.
Base: `b3de8e03` from `pixel/youzi-image-tool-failure`, retaining the earlier
chat-media/error handling work. This is a UI-only change, not a backend, schema,
model-policy, main integration, or public release change.

## Interaction contract

- Center the entire new-task welcome group horizontally and vertically in the
  right viewport. If its content is taller than the window, scroll instead of
  clipping the composer.
- Primary shortcuts are New Task, Experts/Skills/Connectors, About Me, Results.
  Workspaces remains reachable through its section's More action and existing
  routes; there is no duplicate shortcut under New Task.
- Tasks and Workspaces headers sit outside their inner scrolling lists. Default
  viewports fit up to five complete rows, shrinking with window height and font
  scale. This caps the viewport, **not the data**: all items remain scrollable.
- More opens the complete collection in the right pane. The Tasks page shares
  canonical records and existing row actions; it supports search and All/Pinned.
- Expand removes the inner viewport cap and pushes the following section down.
  The collections' outer scroll view owns overflow and pins the active section
  header so Collapse stays reachable. Brand, primary shortcuts and footer are
  outside that scroll view. Collapse resets the appropriate scroll anchor.
- Retain the two brand/footer separators; do not restore separators between the
  three primary content areas.

Implementation: `YouziSidebarMetrics`, `YouziSidebarSection`,
`YouziCenteredWelcome`, `YouziSimpleTasksPage` in `UI/YouziSimple/`.

## Verification

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 YOUZI_SIDEBAR_VISUAL_QA=1 \
  swift test --package-path apps/rapid-mac \
  --filter 'YouziSidebarLayout|YouziSimpleWorkbench|YouziExperienceMode|YouziAccountMenu|YouziChatArtifact|YouziSimpleTranscript'
```

The scoped run passes 27 tests across seven suites. Layout math covers heights
400/600/900/1200/1800 and all four font scales. Synthetic rendering covers short,
tall, task-expanded, workspace-expanded, both-expanded and English states, with
22 rows per collection. PNGs go to the OS temporary directory under
`youzi-sidebar-visual-qa`, never into user history or the repository.
Each rendering case needs a fresh SwiftUI `.id` to reset initial `@State`;
replacing `NSHostingView.rootView` alone reuses prior expansion state.

The old workbench lifecycle test compared declaration positions. At the base
commit, `submit` already called `prepareTaskRequest` before `chat.send`, with
`beginTaskExecution` inside the helper declared later. The test now follows
that call sequence; production submission behavior is unchanged.

Native acceptance should additionally exercise collapsed scrolling, both More
routes, expand/outer-scroll/collapse, a short window, welcome centering and fixed
footer. Do not claim model inference or a full repository suite from this gate.

## Local delivery / rollback

Build in this task worktree with `RAPID_DESKTOP_NO_PORT_SWEEP=1` and an exact
`RAPID_CANDIDATE_IDENTITY=candidate-<eight-digit-code-commit>`. Use the full
`apps/rapid-mac/scripts/build.sh` sidecar build. Verify deep strict code signing,
flat bundle resources, and the bundled engine's `--version` before switching.
Do not mutate any currently running app bundle or use port-sweeping termination.
Quit the exact idle client normally, open the new worktree bundle, and retain the
previous complete bundle as rollback. No model files or preferences need changing.
