# Sidebar scroll indicators — 2026-10-07

Owner: Pixel. Integration receiver: Atlas. Host: Local Mac. Branch:
`fix/youzi-sidebar-visibility-20261007`, based on `fix/youzi-know-me-review`.
Role files and Orca are absent; the repository AGENTS.md applies.

The September 30 SwiftUI `.hidden` modifier did not suppress the native tracks
in the user's live window. The task is limited to the outer collections viewport
and its two collapsed lists in Simple Mode. Navigation and other page scrollbars,
sidebar sizing, all rows, sticky section headers, expansion, and ScrollViewReader
navigation remain unchanged. No public API, data schema, or model behavior changes.

Each collection ScrollView now embeds a non-interactive AppKit probe inside its
content. It attaches only to the nearest enclosing native scroll view, preserving
independence of nested viewports. The native scroller and its fixed gutter remain
installed; its painting and hit area are hidden when idle, visible while hovered,
and revealed by actual clip-origin changes or live-scroll notifications. Motion
refreshes a 1.2-second idle deadline. Hover preserves visibility after that deadline;
exiting hover hides an idle scroller immediately. A fixed native legacy style avoids
an independent overlay fade overriding the hover state and avoids row width shifts.
This changes only these viewports, without writing macOS preferences.

The probe observes layout and native motion, cancels delayed work on detachment,
removes its observers, and restores the native style and visibility. No polling,
private API, swizzling, wheel interception, or replacement scroll implementation
is required. The source is compatible with the macOS 14 target.

Verification: four native AppKit regression journeys passed in an isolated package
using the production probe: idle/hover with stable content frame; scrolling from
hidden state and deadline refresh; nested independence and persistent hover;
detachment with cancellation. Full release desktop regression and visible-window
acceptance are pending at this checkpoint. Existing About Me tests use isolated
fixtures; no real memory fact is confirmed or saved for acceptance.

Reproduce the scoped desktop verification with:

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac \
  -c release --jobs 6 --no-parallel \
  --filter 'YouziSidebarScrollIndicatorTests|YouziSidebarLayoutTests|YouziKnowMeTests|YouziComposerControlsTests|YouziSimpleWorkbenchTests'
```

Delivery is a local preview only. No production release or installed app replacement
is requested. After acceptance, integrate the dependent September 30 fixes as well,
push the integration branch, verify inclusion and worktree state, and retire the
three task worktrees through system Trash while retaining branch refs and recovery
records. The main working directory's September 30 copies must be preserved before
fast-forwarding; they must first be proved byte-identical to their committed source.
