# Chat table rendering

Assistant messages use `TextKitMarkdownView` or `StreamingTextKitMarkdownView`.
Text/code use the text renderer; compiled GFM tables use the native SwiftUI
`MarkdownTableView` in `MarkdownBlockStack.swift`, **not HTML/CSS**. The older
MarkdownUI theme is not the active table path for these messages.

A SwiftUI `Grid` aligns columns, but a `Text` cell still has its own intrinsic
width unless it accepts the column's width. Backgrounds and divider overlays
attached to that shorter cell used to stop before the end of the column. An
empty header and center/right alignment made the problem especially visible.

Every cell now accepts `maxWidth: .infinity` within its column before padding,
header background and divider overlays are applied. Its existing row-height
fill is retained. This keeps complete header fills and single shared grid lines,
while preserving native horizontal scrolling, GFM alignment, inline styling,
rounded outer borders and the native accessibility-table representation.

## Regression check

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 \
YOUZI_MARKDOWN_TABLE_RENDER=1 \
YOUZI_MARKDOWN_TABLE_RENDER_DIR=/tmp/youzi-markdown-table-render \
swift test --package-path apps/rapid-mac -c release \
  --filter 'MarkdownTable|MarkdownChrome|TextKitMarkdownParity'
```

Synthetic fixtures contain an empty header, unequal header/body widths, all
three alignments and a multiline cell. Diagnostic colors measure full-width
header coverage and complete horizontal/vertical divider bands. Color detection
uses channel dominance because native bitmap capture converts colors to the
display profile. Real-theme captures also cover light/dark, narrow scrolling and
small/extra-large text. These are native view tests, not model inference or
browser screenshots. No user chat text is stored in the fixtures.
