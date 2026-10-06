# About Me review and composer polish

Owner: Pixel. Host: Local Mac. Receiving role: Atlas integration. Branch
`fix/youzi-know-me-review` depends on `fix/youzi-composer-sidebar-polish`.
Role files and Orca were unavailable; the repository AGENTS.md applied.

The empty About Me page was a presentation gap: schema-v4 legacy migration
preserves memories as `proposed`, but the page filtered out every state except
`confirmed`. It offered neither review nor a creation path. Automatic extraction
remains opt-in, idle-local-model-only, and restricted to newly authored messages;
remote chat neither extracts nor injects this memory store.

About Me now shows imported and new proposals separately from confirmed facts,
offers per-record confirmation and manual entry, links to Memory Settings, and
surfaces persistence/queue errors. Actions use the existing app-owned MemoryStore
and domain graph. Card/section accessibility containers preserve each button's
identifier instead of overwriting it. Settings still owns editing and forgetting.
The product graph, migration, confirmation and privacy policies are unchanged.

The dependency branch removes the glossy sphere shading, uses muted theme hues
and a 24-point indicator while retaining the 44-point picker hit area and readiness
sectors. Sidebar indicators are hidden until each scroll viewport is hovered;
native scrolling, viewport budgets and expansion behavior remain intact.

Verification on macOS 27 / Apple Swift 6.4:

- The isolated production memory/domain package passed 52 tests in six suites.
- Release desktop tests passed 62 tests in ten suites, including three new native
  accessibility journeys: eight migrated proposals, confirmation plus restart;
  manual save with collection off plus remote-mode explanation; failed write with
  unchanged bytes and visible error. Manual input begins with an explicit fixture
  draft because an AX value assignment alone does not model native text editing.
- Composer renders passed Chinese/English, four font sizes, and both appearances.
  Light and dark medium renders were visually inspected.
- Swift frontend parsing and `git diff --check` passed.

Reproduce with `python3 apps/rapid-mac/scripts/test-memory-isolated.py`, then:

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 YOUZI_COMPOSER_RENDER=1 \
swift test --package-path apps/rapid-mac -c release --jobs 6 --no-parallel \
  --filter 'YouziKnowMeTests|MemoryStoreTests|MemoryExtractorTests|YouziMemoryServiceTests|YouziMemoryIngestionQueueTests|YouziComposerControlsTests|YouziRemoteAvailabilityTests|YouziComposerRenderTests|YouziSidebarLayoutTests|YouziSimpleWorkbenchTests'
```

Next user action: review imported content before confirming it. No actual model
inference, history scan, remote extraction, file/connector ingestion or graph
workbench redesign is claimed by this fix. Atlas owns integration and the complete
signed local preview; runtime observations and recoverable cleanup provenance are
kept in the local launch audit. No production release is requested.

September 30 integration status: the checked source has been copied to the main working directory. This session makes `.git`, `.agents`, and sibling worktrees read-only; Git integration and recoverable worktree cleanup remain pending. Preserve both task branches and worktrees until integration is writable.

Local preview: `apps/rapid-mac/build/Youzi Review Preview.app`, candidate `728baa81`. The app uses the release executable from the passing native test build and unchanged engine/resources from the verified base app; ad-hoc deep strict signature verification passed. Audit evidence is in ignored `apps/rapid-mac/build/ui-memory-audit/`. The running app has not been replaced: Computer Use returned “Computer Use was not approved to use Youzi”. Actual live draft typing and sidebar hover inspection remain pending. The user’s memory data has not been changed or automatically confirmed.

All 13109 non-signature resource files are byte-identical to the verified base app. Re-running the protocol smoke under current sandbox restrictions is blocked by Metal GPU access: a minimal `mlx.core` import fails identically for both the base and preview. The previously successful base protocol smoke is preserved in the audit; this task changed only native UI code. Do not interpret the sandbox smoke as live model acceptance.

October 7 follow-up: app-control and filesystem restrictions have been lifted. The local review preview was launched and About Me visibly showed eight imported candidates and their confirmation controls. The original sidebar indicator approach still left native tracks visible; the corrected policy and current acceptance status are documented in `2026-10-07-youzi-sidebar-scroll-indicators.md`.
