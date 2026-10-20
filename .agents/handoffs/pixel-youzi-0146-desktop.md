# Youzi 0.14.6 desktop backports

- Owner: Pixel; receiving role: Atlas.
- Branch: `fix/youzi-0146-desktop`; base: `7992b761`.
- Host: Local Mac, arm64, macOS 27.0.1 (26A434), Apple Swift 6.4.
- Goal: preserve interrupted replies and independently complete conversation titles; create private store files with owner-only access before writing their bytes.
- Scope: desktop sources, matching regression tests, this handoff. No version, release, UI styling, remote settings key, or main-worktree changes. Role files are absent from this checkout.

## Adaptation

Backported upstream `0c2de4835240f4a91623f2f6d6fd27176549c4d2` (#4940):

- Conversation switches, New Chat, and termination synchronously finish partial assistant rows and pending tool shells before saving.
- Loaded stale streaming rows on both the visible path and saved branches are repaired and saved without changing conversation ordering.
- Titles are conversation-owned tasks. Switching conversations preserves them; sends, retries/regeneration, branch changes, message deletion, and conversation deletion cancel stale attempts.
- Youzi's memory foreground hook, extraction scheduling, remote background-work gate, conversation/task observer, and live-voice branch invalidation remain intact.
- New tests use the existing in-process HTTP fake directly with `ChatViewModel`; they do not mount windows or automate UI. They additionally verify the Youzi observer receives the stopped transcript and a cancelled title cannot overwrite or remove a newer attempt.
- The old `deliverBackgroundReplies` helper and its helper-specific test are superseded by independent title tasks and the new lifecycle regression suite.

Backported upstream `7df53b10aa12233e4f2db6c9c010c2eeff9ec27d` (#4904):

- Shared `OwnerOnlyFile.writeAtomically` creates a same-directory `mkostemp` file with close-on-exec, writes and syncs it, then atomically renames it.
- Conversation history, folders, MCP configuration, telemetry identity, crash markers, and browse cache use it.
- Draft and document-cache modules from upstream are absent in this Youzi baseline and were not introduced.
- Tests verify the temporary file's permissions and zero size before the first byte, descriptor inheritance protection, replacement permissions, cleanup on error, empty data, and preservation of existing content on failed replacement.

## Verification

From the worktree root:

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test \
  --package-path apps/rapid-mac \
  --scratch-path apps/rapid-mac/.build-desktop-0146 \
  --no-parallel \
  --filter 'ConversationSwitchStreamingTests|OwnerOnlyFileTests|ConversationHistoryTests|ConversationFolderTests|BackgroundAssistGatingTests|TelemetryTests|MCPConnectorsTests|BrowsePaginationTests|YouziConversationBridgeTests|MessageBranchingTests|ChatMessageActionsTests|ReasoningContentFallbackTests|LiveVoiceNativeChatRouteTests|YouziMemoryIngestionQueueTests|CrashReporterSignalSafetyTests'
```

Passed: 220 Swift Testing tests in 19 suites plus 8 XCTest tests, zero failures. `git diff --check` passed. Full desktop source and test compilation succeeded. Existing snapshot-resource and Swift 6 UI isolation warnings remain outside this change.

The completed scratch directory is retained under ignored `apps/rapid-mac/build/desktop-0146-scratch`; it has been moved after the run and should not be reused as an incremental build cache. Log: `/tmp/youzi-0146-desktop-tests.log`.

## Integration

No unresolved implementation questions. No production model, microphone, or visual UI run was performed; these are deterministic persistence/lifecycle/permission checks. Atlas should review and cherry-pick this branch, run integration/release validation, and own the authorized release. This workstream does not push, merge, or publish.
