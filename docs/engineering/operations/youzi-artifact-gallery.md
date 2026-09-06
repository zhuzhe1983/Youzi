# Youzi deliverable gallery

## Behavior

The Results/成果 page uses one square-preview grid for all eight artifact kinds.
The small, medium, and large settings have minimum preview edges of 144, 208,
and 288 points; the responsive grid distributes the remaining row width. The
selection persists in `youzi.results.cardSize`. Titles sit below each preview,
wrap to two lines, and expose their full value on hover. Rows align at the top.
Existing category filters and title/content search remain available. Finder,
export, and sharing actions live in each card's ellipsis menu. The old list-mode
picker and unimplemented cloud-sync claim have been removed.

- Images: real, orientation-correct thumbnails cropped to the square card.
  Clicking opens an in-app dark overlay without cropping the full preview.
  Fit, 1:1, zoom buttons, wheel/pinch zoom, and drag-to-pan are supported.
  1:1 maps an original image pixel to a physical display pixel, accounting for
  the display's backing scale. Zoom is clamped to 1%–1600%.
- Video: an actual first-frame thumbnail, and a native `AVPlayerView` overlay
  with aspect-preserving playback, standard floating controls, and fullscreen.
- Audio: click to play/pause immediately. A compact playback row displays the
  current title and pause/stop controls. Starting another audio/video stops the
  previous player; there is only one playback owner for the gallery.
- Documents, code, and other files: square icon/text preview cards with the
  existing document/text preview callback. No new HTML execution path is added.
- Escape, the close button, or a backdrop click dismiss the media overlay.
  Leaving Results stops playback. Missing/corrupt/unsupported media produces
  an explicit placeholder or an error, not an external application launch.

## File ownership and resource limits

`YouziMediaFileLease` retains the **original file or workspace-folder** security
scope until the decoder/player's last owner goes away. It does not return an
unscoped URL from a short synchronous access closure. The existing lexical and
symlink checks and stale-bookmark persistence are retained. Revoked files cannot
acquire a media lease. Nothing is copied into a second media library.

The product model resolves leases off the main actor and does not republish the
entire observable domain document when a lazy cell requests a thumbnail. Image
and video thumbnail decoding also run off the main actor. Cancellation and
late selection completions cannot reopen a dismissed overlay or replace a newer
selection. Player status/end observers are removed when their owner is released.

Thumbnails are bounded to 640 pixels per edge and cached in memory with a 48 MiB
cost budget / 160-entry count limit. Overlay bitmaps are bounded to 8192 pixels
per edge and approximately 16 megapixels. Very large originals therefore use a
downsampled preview while retaining original pixel dimensions for navigation;
the original file is never modified. This is not a tiled, unlimited-resolution
image editor. Format support follows the local ImageIO/AVFoundation decoders.

## Verification

Run from the task worktree, without starting/stopping the real client or servers:

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac \
  --filter 'YouziArtifactMediaTests|YouziSimpleWorkbenchTests|YouziManagedFileStoreTests|YouziWorkspaceAccessTests|YouziLifecycleRepositoryTests|YouziProductModelTests|YouziDomainTests|YouziDomainIntegrityValidatorTests|YouziDomainMigrationTests|YouziConversationBridgeTests|YouziTaskDataSecurityTests|YouziLocalModelToolsTests'

RAPID_DESKTOP_NO_PORT_SWEEP=1 YOUZI_GALLERY_VISUAL_QA=1 \
  swift test --package-path apps/rapid-mac --filter YouziArtifactMediaTests

RAPID_DESKTOP_NO_PORT_SWEEP=1 swift build --package-path apps/rapid-mac -c release
```

The visual test creates an isolated native window and synthetic PNG, WAV, and
H.264 MOV files. It checks all card sizes, a narrow English layout, actual card
clicks, image wheel/drag/1:1, Escape dismissal, video ready-to-display, and
backdrop dismissal/player detachment. Temporary captures go into
`$TMPDIR/youzi-gallery-visual-qa`; no real task history or runtime is accessed.
Add `YOUZI_GALLERY_INTERACTIVE_QA=1` to hold the video window for 60 seconds for
an OS-level capture. `NSView.cacheDisplay` does **not** capture AVPlayer's video
surface; use the OS window capture to inspect actual video pixels.

Native player integration is intentional: the SwiftUI `VideoPlayer` wrapper
crashed during this task's SwiftPM-hosted visual test with a superclass-resolution
failure. Directly using `AVPlayerView` links AVKit and passed the same journey.
The backdrop uses a plain button so dismissal also works on the first click in
an inactive native window.

## Integration and rollback

No schema migration, model service/API change, runtime replacement, or model
operation is part of this task. Integrate the gallery commit after the local
multimodal-tools base. Keep the local Youzi UI when resolving upstream conflicts.
Rollback is the gallery code commit's revert/replacement with the prior client;
there are no artifact bytes or domain records to restore. The optional card-size
preference is harmless to an older client.

A successful Swift release build is not a signed/notarized installer, an installed
client update, a completed GUI multimodal-generation journey, or a GitHub release.
