# Pixel → Atlas: chat artifact previews and image-owner fix

- Owner/host: Pixel, local Mac. Branch: `pixel/youzi-image-tool-failure`.
- Base: `717e4455` from `pixel/youzi-markdown-table-fill`, preserving the delivered
  native model table, compact model header, mode switch and Markdown table fix.
- Dedicated Git worktree. Role files/Orca are unavailable; no agent delegation.
- Receiving owner: Atlas for review of the narrow backend lifetime repair and
  later main integration. No public API or residency policy change.

## Verified

- Successful image tool receipts were persisted with saved artifact/file UUIDs,
  but both chat renderers showed only ToolCallChip, with no artifact projection.
- Both modes now render one shared, task-validated output card outside the chip.
  Existing managed files, thumbnails, playback and image/video overlay are reused.
  Audio and HTML have direct actions; no duplicate file or chat schema created.
- Python selected regression suites: 263 passed, including five owner/cancellation
  regressions with a fake thread-bound model.
- Native selected tests: 40 passed, including isolated visual rendering. Receipt restore,
  all four output kinds, rejecting unsafe/mismatched references, localized image
  failures and existing media lease/playback coverage are included.
- Actual cached Z-Image, fixed source with bundled dependency runtime, offline,
  Apple M5 Max/128 GiB/macOS 26.6.2: preload plus 3 sequential 512-square/4-step
  renders from distinct caller threads all produced decodable nonuniform PNGs;
  owner cleanup completed. No model downloads or user domain writes.
- New UI screenshots are synthetic shared-component fixtures, not an end-to-end
  client/LLM acceptance result. See the operations note for reproduction.

## Backend risk / review

Serializing `to_thread` calls did not preserve the image model's MLX owner.
The per-image worker owns load/render/encoding/release, drains cancellation and
retires once stopped. It deliberately does not use chat's worker, to avoid long
denoise jobs blocking chat/audio or tying image lifetime to chat switching.
Failed/canceled dynamic preload drains and closes the orphan adapter.

Review multi-image-instance interactions and other image families separately;
the live reproduction and correction acceptance covered Z-Image. No global MLX
stream mutation, forced unloading of another modality or raw error persistence.

## Delivery and next action

- Main and the installed app are untouched. No release authorized for this task.
- Complete paired local build and installed-resource/signature checks before
  switching clients. Never modify the running sibling worktree's bundle.
- Use `RAPID_DESKTOP_NO_PORT_SWEEP=1` for every native test/build/launch.
- Verify zero active user work, quit normally and keep the prior candidate for
  rollback. Validate historical output cards in the actual client after launch.
- Integrator: review this task branch together with its prerequisite UI branches,
  not an isolated cherry-pick onto old main that drops recent user work.
