# Remote model Keychain authorization recovery

Superseded on 2026-10-20 at the user's request: remote model credentials now belong to [Youzi settings](../decisions/2026-10-20-youzi-remote-settings-keys.md). The interactive authorization flow below is historical and has been removed.

Owner: Atlas (credential architecture/integration), Pixel (editor/recovery UI), local Mac. Role files are absent. This follow-up repairs the 0.14.5 regression without changing model protocols, credentials, Keychain ACLs, or published release assets.

## Failure and fix

The 0.14.5 startup fix routed remote credentials through the non-interactive Keychain adapter. That prevented a legacy login-keychain authorization prompt from blocking launch, but also made an inaccessible saved key unrecoverable in the remote-model editor. The editor surfaced `-25308` before sending `/models`. This is an app-side credential access failure; it does not establish that the server rejected the API key.

Background discovery remains non-interactive. If a saved key is inaccessible, the editor offers **Authorize key access and retry**. Only that user action permits a system Keychain prompt. The requested account must belong to the configured model or the explicitly selected source at the exact same normalized API base. Authorization runs off the main actor. Cancellation and changes to the source configuration discard the result before any network discovery.

All application-owned SecItem reads, writes and deletions share one gate around the legacy process-wide interaction flag. While an explicit authorization holds it, other operations fail immediately rather than waiting or displaying their own prompts. Every completion restores non-interactive mode; a failed restoration disables further SecItem operations. This serialization is necessary because per-query authentication flags alone do not reliably suppress legacy file-based keychain UI. See [Apple's API](https://developer.apple.com/documentation/security/seckeychainsetuserinteractionallowed(_:)) and [Chromium's documented macOS limitation](https://chromium.googlesource.com/chromium/src/crypto/+/refs/heads/main/apple/scoped_keychain_user_interaction_allowed.cc).

An explicitly authorized key is retained only in process memory for this app run. This supports the system dialog's one-time Allow choice, subsequent discovery, and copying the key to a new model's own Keychain item. Replacement/deletion invalidates that entry, and a generation check rejects older reads. No keys are written to preferences, files or logs. Denied access never becomes an unauthenticated request. Existing persistent Keychain storage and its access controls remain authoritative across restarts.

Legacy SecurityAgent dialogs cannot reliably be cancelled through LAContext. Closing the editor discards its late result and prevents a network request; the user may still need to dismiss the system dialog. The global gate remains held until that operation finishes, and the app stays responsive. This fix does not silently grant access or unlock the user's Keychain.

## Verification and delivery

`RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac --scratch-path <shared-scratch> --filter 'RemoteKeychainAuthorizationTests|RemoteCredentialAvailabilityTests|RemoteModelTests|SettingsWebSearchKeyDraftTests|WebSearchProviderRosterTests'`

93 tests in 11 suites passed, including eight new authorization regressions. Tests use synthetic in-memory credentials and isolated preferences, never the user's Keychain. They cover silent launch reads, gate exclusion/restoration, denial, cancellation, concurrent replacement, source changes, and discover/save after authorization. Actual macOS approval requires the user; automated fixtures do not prove that their stored key has been granted access.

For local delivery, back up the installed complete app and preferences, then clone user data after quitting. Build the native app from the committed fix and retain the already verified 0.14.5 runtime. Mark the app as a source-identified candidate and re-sign the complete bundle. Roll back by restoring the previous complete app without overwriting newer user data. Preserve unrelated main-worktree edits and published 0.14.5 bytes.

Native acceptance on 2026-10-20 used the combined settings/capability-management candidate with the verified 0.14.5 runtime. The complete signed bundle passed deep strict signature verification and launched without a blocking Keychain prompt. Reusing an existing server and testing discovery surfaced the explicit authorization action immediately, including with optional Settings explanations hidden. The unsaved test draft was cancelled. The actual system permission and a successful authenticated request remain unverified until the user grants access; no saved credential or Keychain access control was changed during acceptance.
