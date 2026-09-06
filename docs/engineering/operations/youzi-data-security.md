# Youzi task filing, sharing history, and security

## Behavior

- Task pin/archive/rename actions for linked conversations write through
  `ChatViewModel`, then reconcile into `YouziProductModel`. Never save just a
  copied task's pin/archive/title: selection or startup reconciliation would
  overwrite it from conversation history. Conversation-less drafts remain
  domain-owned.
- Settings → Data Management contains Archived Tasks, Shared Files, and Shared
  Tasks. Archived content is readable without selecting/unarchiving the chat.
  Restore is non-destructive and uses the same canonical filing path.
- Task menus and My Files offer native macOS sharing. Task sharing includes
  visible user/assistant text, not system instructions, tool messages, or
  attachment bytes. File sharing exports a scoped temporary copy; its access
  outlives the synchronous bookmark-access closure and it is cleaned up when
  the service completes, fails, or the picker is cancelled.
- Share history is **local metadata**, not an online link service. A record is
  saved only when the selected service reports success. Records contain source
  identity, title, service, and date, not recipients, paths, or copied contents.
  `YouziDomain/shares.json` is versioned and atomically replaced. Corrupt or
  unsupported data blocks writes instead of being overwritten.
- Removing a share entry never deletes the original or recalls a delivered
  copy. Current source content can differ from what was shared. No historical
  sharing records are fabricated from old file exports.

## Security boundaries

- Security Center uses the same `BrowseApprovalStore` and
  `MCPToolApprovalStore` injected into executing registries. It does not create
  a second set of settings stores. Relaxing approval requires confirmation.
- A remembered MCP grant can be revoked individually or all together. Blanket
  auto-approval is independent; the page warns about this explicitly. The
  revoke-all action also restores browse/MCP ask mode. Running operations are
  not terminated by settings changes.
- Workspace/file checks protect Youzi's managed file paths, not arbitrary
  external processes. Local MCP programs run with user permissions.
- There is **no** universal agent process sandbox, command-prefix allowlist,
  network gateway, pre-edit automatic backup, hosted sharing/revocation, or
  guarantee that remote models/search/connectors keep all data on the Mac.
  These are stated as unsupported rather than presented as enabled toggles.
- Native sharing delivery/recall behavior depends on the selected macOS
  service. The app cannot attest that a remote recipient opened a copy.

## Regression and local verification

Run from repository root:

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac --filter 'Youzi|Settings|MCPConnectors|Browse'
swift build --package-path apps/rapid-mac -c release
git diff --check
```

`YouziTaskDataSecurityTests` exercises real chat/domain persistence, selection,
relaunch, professional-side pin changes, draft restore, local sharing metadata,
corrupt/future format preservation, grant revocation, and idempotent bilingual
heading translation. Environment-injection tests cover both new settings pages.

For a local bundle refresh, use `apps/rapid-mac/scripts/build.sh`. If deliberately
skipping sidecar rebuilding for a desktop-only change, preserve the previously
working bundled engine and re-sign **after** restoring it. Always verify
`@executable_path/../Frameworks`, deep/strict code signature verification,
60+ seconds of process survival, actual Accessibility navigation to both pages,
and `/healthz`. Process presence alone is not successful startup verification.

An external share to an actual recipient is not part of automated smoke tests;
use a disposable document and an explicitly chosen destination for manual QA.
No model-serving/concurrency or capability-center work is implied by these tests.
