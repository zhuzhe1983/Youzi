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
detachment with cancellation. Release desktop regression passed 27 tests in six suites. An additional isolated
SwiftUI-hosting journey proves that the production wrapper attaches to the actual
native viewport and follows its idle/scroll visibility. Visible user-window
acceptance remains pending at this checkpoint: the preview main thread is blocked
in `SecItemCopyMatching` while macOS SecurityAgent waits on Keychain confirmation.
The automation provider forbids controlling SecurityAgent for safety reasons; the
user must handle that OS confirmation. No password or Keychain ACL is changed by
this task. Existing About Me tests use isolated
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

## Integration checkpoint

The production fix and dependent composer/About Me changes were fast-forwarded
into main and pushed to origin/main (`de95beb2`). The original six working-copy
files were proved byte-identical to `728baa81` and preserved in stash
`044310922bef1c07aa5b36f10ed048d85a63247a` before integration. Both earlier task
worktrees were verified clean, included in origin/main, and unused by processes,
then moved with FileManager's system Trash API; branch refs and Git registration
backups are retained. The current source worktree can also be retired after this
record is pushed: no process or pending runtime check needs its directory, because
the signed preview is under the main project's build directory. Runtime follow-up
can continue against main without retaining a completed source worktree.

The final isolated production-probe selection passed five tests in Release,
including actual SwiftUI hosting/attachment. The desktop Release selection passed
27 tests in six suites; the fifth isolated attachment case was added afterward,
without changing production source or the signed native executable. The preview
is `Youzi Sidebar Preview.app`, identity `candidate-16f3751e`. Its process is running,
but user-window acceptance is still blocked by the OS Keychain confirmation.
No password is entered, ACL changed, credential printed, memory fact saved, or
model setting altered for this repair.

Exact original paths, branch commits, Trash URLs, registration backups, and
recovery steps are in the local `.youzi-launch/20261007-sidebar-visibility` cleanup
manifest. Recover only into vacant paths, restore the recorded registration,
then run `git worktree repair` and verify HEAD/status. Do not empty Trash or delete
branch refs. Existing safety backups and the visualizations directory are preserved.
