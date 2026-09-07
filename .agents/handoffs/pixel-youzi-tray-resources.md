# Pixel → Atlas / Harbor: compact tray resources

Owner Pixel, local Mac. Branch `pixel/youzi-tray-resources`, based explicitly on
`atlas/youzi-model-settings` at `47aca95f` (the installed model-settings candidate).
The repository has no `.agents/roles/` files. Main and other worktrees untouched.

Replaced grey status rows with one fixed-width colour card plus a ready-model
submenu. Shared track/palette with scenario picker; CPU/GPU/host memory remain
separate from estimated model budgets. Busy audio stays visible without double
counting. Pending/failed models are not treated as loaded. No API, model-loading,
settings, permission, keychain or preference changes.

Focused Swift checks and Chinese/English, dark/light, ready/empty render checks
pass. English full four-lane legend and Chinese dark output inspected. See
`docs/engineering/operations/youzi-tray-resources.md` for repeatable commands and
native acceptance/telemetry caveats. A complete native-menu interaction test and
candidate packaging/installation are the next integration checks.

Receiving Atlas owns integration with main and the independent video-tools task.
Receiving Harbor owns any formal release; this task does not authorize one.
The user's subsequent live-voice request is a separate assessment, including
streaming replies and acceptable push-to-talk half duplex; this UI patch does
not implement a real-time voice controller.
