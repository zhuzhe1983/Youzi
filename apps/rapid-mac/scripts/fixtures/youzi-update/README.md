# Local Sparkle installation acceptance

From `apps/rapid-mac`, after Sparkle 2.9.5 has been resolved:

```sh
python3 scripts/smoke-youzi-update.py
```

To reuse an existing resolved checkout without building Youzi:

```sh
python3 scripts/smoke-youzi-update.py \
  --sparkle-root /path/to/.build/artifacts/sparkle/Sparkle \
  --sparkle-source /path/to/.build/checkouts/Sparkle \
  --output /tmp/youzi-update-acceptance
```

The output directory must not exist. Without `--output`, a new private temporary
directory is created. Run as a normal logged-in macOS user with Xcode command-line
tools, Python 3, and a graphical login session for Sparkle's launchd helpers.
No user interaction is requested. The default per-case timeout is 90 seconds.

The harness compiles the unchanged upstream `sparkle-cli` Objective-C sources
against Sparkle 2.9.5. A fresh CryptoKit Ed25519 seed signs every archive and feed
using the official `sign_update --ed-key-file` command. The seed is deleted in
`finally`; no keychain or release key is used. A server bound only to `127.0.0.1`
serves a new feed and archive for each case:

| Case | Required result |
| --- | --- |
| Valid signed update | CLI exit 0; download occurs; Sparkle reports installation finished; bundle advances from 1 to 2; resource advances; installed code signature verifies |
| Archive bytes changed after signing | CLI exit nonzero, Sparkle error 4005; archive requested; old bundle hash and version unchanged |
| Wrong enclosure signature in a validly signed feed | Same rejection and unchanged bundle |
| Feed bytes changed after signing | Sparkle error 1000; no archive request; old bundle unchanged |
| Unsigned feed | Same rejection before archive download |

Both fixture versions set `SURequireSignedFeed` and
`SUVerifyUpdateBeforeExtraction`. The apps are ad-hoc signed. Only Sparkle's
actual installer performs replacement; the harness never replaces the installed
test bundle itself.

`result.json`, `requests.json`, and each case's `sparkle.log` retain the evidence.
The negative cases compare the entire bundle's paths, permissions, symlink
targets, and file bytes. Per-run IDs and absolute `SUDefaultsDomain` paths isolate
preferences; `CFFIXED_USER_HOME` isolates the driver's Foundation caches without
changing `HOME`. Sparkle's launchd helpers do not inherit that environment and
can create cache directories under the real home. After verifying those helpers
have exited, the harness moves only their exact per-run cache directories into
`native-helper-caches` in the output directory. A read-only check then requires no
fixture preferences/cache artifacts remain in the real home. The test terminates
its CLI on cancellation or timeout and removes only its unique Sparkle launchd
jobs. Other apps and processes are left alone.

This proves a real Sparkle update for a disposable app. It does not prove the
production Youzi package, update UI, running-app termination/relaunch,
authorization for protected destinations, Developer ID/notarization, or production
HTTPS/CDN behavior. Those require separate acceptance. No model is loaded, no
installed Youzi is touched, and no production feed is contacted.
