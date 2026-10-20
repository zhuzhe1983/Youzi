# Vector → Atlas: local Sparkle installer acceptance

- Branch: `test/youzi-update-smoke`; base `f179cdf34`.
- Owner: Vector validation workstream, delegated by Atlas under the Butler run.
- Host: local Mac, Apple silicon, macOS 27.0.1 (26A434), Apple clang 21.0.0,
  Python 3.14.7 (recorded by the harness). Assigned role files were absent.
- Goal: exercise Sparkle 2.9.5's real download, validation, extraction, and
  replacement using isolated old/new apps and a loopback feed.
- Scope: the smoke runner and fixtures only; no Youzi launch, models, installed
  app mutation, production feed, release key, keychain access, or production
  release. No push or merge is part of this delegated task.

## Verified evidence

The runner compiles the unchanged official `sparkle-cli` source at Sparkle 2.9.5
(`79bc9e872948e47877e76f194cb0c8e0412b0b90`) against the corresponding resolved
framework. It uses the framework's actual installer; there is no replacement
implementation in the harness.

A fresh CryptoKit Ed25519 seed is used with official `sign_update --ed-key-file`
for archives and feeds. Both test bundles require signed feeds and verification
before extraction. Ad-hoc code signing does not block this setup:

- Valid update installs successfully and advances the bundle/resource version
  from 1 to 2; installed `codesign --verify --strict` passes.
- A damaged archive and an incorrect enclosure signature both fail with Sparkle
  error 4005, leaving the old app's full content/mode/path hash unchanged.
- A tampered feed and an unsigned feed both fail with Sparkle error 1000 before
  requesting an archive, also leaving the old app unchanged.

Run instructions and coverage boundaries are in
`apps/rapid-mac/scripts/fixtures/youzi-update/README.md`. Results include logs,
request records, toolchain metadata, source hashes, and cleanup checks. A fresh
output directory is required; it is intentionally retained for review. The
private test seed is deleted even on failure.

Sparkle preferences use absolute `SUDefaultsDomain` paths and remain inside the
run output. The driver uses `CFFIXED_USER_HOME`, but launchd helpers do not inherit
that variable and create per-fixture caches in the real user cache directory.
The harness verifies helper termination, then moves only those exact unique cache
domains into its output and checks for no remaining fixture home artifacts.
Existing user apps, preferences, cache domains, and processes are not touched.

Final local evidence: `/tmp/youzi-update-acceptance-05/result.json` reports
`passed: true`, all five cases passed, no owned helpers remaining, no fixture
artifacts remaining in the real home, and the disposable seed was removed.
The run used `--sparkle-root` and `--sparkle-source` pointing at the existing
resolved artifact and checkout under the primary worktree's
`apps/rapid-mac/.build`; it did not use uncommitted application code.
Earlier exploratory runs' unique helper caches were also collected into their
own `/tmp/youzi-update-acceptance-01` through `-04` output directories.

## Limits and next action

Receiving owner: Atlas. Run the harness after integration, then independently
check the final production bundle's signing/configuration and native UI wiring.
This task does not cover running-app termination/relaunch, UI prompts,
Developer ID/notarization, protected `/Applications` authorization, or production
HTTPS/CDN. These remain explicit acceptance boundaries, not successful claims.
No architecture change is required for ad-hoc apps using valid Ed25519 updates.
