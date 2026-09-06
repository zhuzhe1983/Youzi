# Desktop-native multimodal tools

Atlas owns integration/release; Pixel owns the scenario picker and approval UI.
This work extends the local-delivery branch; it does not change main or migrate
other worktrees' uncommitted work.

## User contract

Simple and Professional chat advertise five built-in function tools through the
same native executor used alongside MCP: `youzi_models`, `youzi_load_model`,
`youzi_generate_image`, `youzi_synthesize_speech`, `youzi_create_storybook`.
These are native tools, not a separately hosted MCP server. Existing tool opt-outs
are preserved when the service is attached after chat initialization.

Discovery distinguishes downloaded from ready. Starting a stopped downloaded
image/TTS model requires the shared UI approval sheet; generation never silently
downloads or starts models. Refusals are remembered for the current task/turn.
A tool argument cannot approve itself. Loading does not restart chat; same-lane
audio can replace a previous audio model, and memory admission may reject a load.
No claim is made that arbitrary models remain resident under all memory pressure.

Generated PNG, WAV and HTML files belong to the initiating task even if selection
changes while a call is awaiting completion. HTML accepts structured text and
same-task managed image/audio artifact IDs, escapes text and embeds media with a
fixed CSP. No arbitrary path reads, remote URLs or executable HTML/scripts.
Limits: 1–8 pages, 20 MiB per embedded asset, 64 MiB per book. The ordinary tool
budget remains 3; an actual local multimodal tool call unlocks 24 total calls
once, only with the full generation suite enabled.

Video generation, audio interpretation/STT and a dedicated image-description
tool are not implemented here. Existing vision attachments remain separate.

## Scenario selector

Four scene tabs show downloaded models, actual residency checkmarks and More
links to corresponding settings. Catalog failures are not rendered as an empty
installed-model list. The memory bar distinguishes model types, other usage and
remaining host memory. Unloaded file size is explicitly labeled disk; unknown
audio allocation remains unknown rather than fabricated.

## Verification and packaging

Always use `RAPID_DESKTOP_NO_PORT_SWEEP=1` for Swift tests on a developer machine.

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac \
  --filter 'Youzi|ModelResidencyTests|ToolLoopBudgetIntegrationTests|ChatToolLoopBudgetGoldenTests|BuiltinToolsTests|AudioClientTests|ModelGenerationDefaultsTests|CustomInstructionsTests|SettingsRouterTests'
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift build --package-path apps/rapid-mac -c release
```

2026-09-06: 190 tests in 29 suites passed; release compilation passed. The opt-in
`YouziMultimodalLiveTests` was separately run against an explicitly owned offline
loopback service (never port 8000), Qwen3.8-27B 4-bit, Z-Image-Turbo and Qwen3-TTS
4-bit. Actual LLM-selected tool calls produced a 512×512 image, 10.08-second WAV
and embedded offline HTML; all three models were resident, with zero evictions.
This is a functional observation on M5 Max / 128 GiB, not a performance benchmark.
The test uses temporary artifacts and a test-only approver: **it is not GUI
acceptance and creates no conversation in the user's app**.

The engine must start with `--enable-audio`; without it the speech route returns
404. Desktop already sets this flag. Do not misdiagnose that 404 as an alias bug.
Voice requests use canonical model identity while preserving alias-keyed defaults.

Installation must replace the complete app and active runtime override, not just
the Swift executable. Follow [delivery and rollback](youzi-delivery.md). Back up
both app locations if the running app is in a worktree, runtime, data and defaults.
Quit the exact app normally and verify its service has stopped. Overlay-copying
onto an old bundle can retain stale sealed resources: replace with a fresh bundle
and run `codesign --verify --deep --strict` before launch.

This delivery uses the verified incremental runtime from the co-residency work,
not a clean-room sidecar rebuild. Packages are ad-hoc signed, not Apple-notarized;
no model weights or user data belong in release assets.

## 0.14.2 native GUI acceptance — blocked, not released

The 0.14.2 (172) bundle was assembled and ad-hoc signature verification passed,
then installed with the matching active runtime override on 2026-09-06. The
client and health endpoint remained alive beyond 60 seconds. Native chat invoked
model discovery and image generation; one task-linked managed PNG was saved.
The main UI subsequently became unresponsive before narration/HTML completion.
Sampling showed the main thread repeatedly in AppKit/SwiftUI layout; this is
symptom evidence, not a confirmed root cause. Backend health still returned 200.
A normal AppleEvent quit timed out. Per delivery safety policy, no force kill or
second replacement was performed. GUI acceptance therefore FAILED; do not
publish this version or emit an updater manifest until recovery and retest.

The native AX `set-value` operation reported success but did not update the
SwiftUI compose binding: the existing draft, not the injected test prompt, was
submitted. Future native automation must use actual text input/paste and verify
the compose value and the resulting user message before proceeding. Never treat
an AX setter's success as evidence that the app's model state changed.

Next: obtain approval to terminate only this hung client and its exact owned
server (with a new stopped-state backup where possible), then diagnose and fix
the layout stall. Retest in a distinct test task with verified input, real startup
approval, image + TTS + HTML artifact creation, offline playback, follow-up chat
and a final residency check. Do not import a test transcript to simulate success.
