# Compact Simple Mode workspace layout

Owner: Pixel, Local Mac. Based on the supplied WorkBuddy desktop reference.

The previous sidebar allocated one third of the window height to navigation
and another third to each collection. Tall windows therefore separated related
items with large empty regions. The new sidebar uses content-sized branding and
navigation, consistent row/section spacing, and top-aligned task/workspace
sections. The account menu remains fixed at the bottom. Sidebar width is
240–320 points with a 264-point ideal width.

Default lists show up to five whole rows; short windows reduce that budget.
Sparse lists reserve only their actual row count (or one empty-state row), and
expanded lists flow into the outer collection viewport. All records remain
reachable by scrolling, expanding, or the existing More routes. Collection
headers show counts and keep More/expand actions with existing accessibility
labels. Indicators retain the native idle/hover/scroll policy.

The welcome composer and skill strip now share a wider 960-point desktop
measure, shrinking with the detail viewport. The logo and headline are quieter;
chat transcripts retain their existing reading measure. This is a presentation
change only: model selection, task execution, voice, persistence, and Know Me
behavior are unchanged.

Validation command:

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 YOUZI_SIDEBAR_VISUAL_QA=1 \
  swift test --package-path apps/rapid-mac -c release --jobs 6 --no-parallel \
  --filter 'YouziSidebarScrollIndicatorTests|YouziSidebarLayoutTests|YouziComposerControlsTests|YouziSimpleWorkbenchTests'
```

The existing layout fixtures cover short/tall, independently expanded
collections, both expanded, and English. Native indicator regressions cover
idle visibility, hover retention, scroll feedback, teardown, and attachment to
the production SwiftUI wrapper. Local preview assembly reuses unchanged engine
and resources from the previously verified sidebar preview and replaces the
newly built native binary, then checks a deep strict ad-hoc signature. No model
inference or real memory writes are part of these UI checks.

Validation and live review results will be recorded before delivery. This is a
local preview, not a production release or deployment.
