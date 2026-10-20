# Remote model settings storage

- Owner/receiver: Atlas / Pixel, local Mac. Branch `fix/youzi-remote-settings-keys`, based on `e372f30e`. Role files are absent.
- Explicit user instruction: store remote model API keys in Youzi settings. All five remote workflows share this store. Remove the prior interactive Keychain authorization path and button.
- Migration makes one silent attempt for existing model IDs without new records. Readable keys move to settings; unavailable keys persist a re-entry state. Subsequent requests do not repeat the legacy lookup or silently become anonymous. Model configuration is preserved, and the legacy items are left for rollback.
- Tests use isolated defaults and synthetic credentials. The remote-model storage/protocol, web-search and settings-environment suites pass; the optional screenshot test is skipped under the default test configuration and will be covered by native acceptance. Real inaccessible credentials cannot be recovered without user re-entry; do not read or log other credential sources to work around this.
- Preserve unrelated uncommitted main-worktree edits. Build with `RAPID_DESKTOP_NO_PORT_SWEEP=1`, use the verified 0.14.5 runtime for local delivery, and do not overwrite public release assets.
- Decision and recovery: `docs/engineering/decisions/2026-10-20-youzi-remote-settings-keys.md`. Record final verification and local migration outcome before integration.
