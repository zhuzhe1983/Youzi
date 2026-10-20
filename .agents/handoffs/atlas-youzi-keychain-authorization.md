# Remote model credential recovery

- Owner/receiver: Atlas and Pixel, local Mac. Branch `fix/youzi-keychain-authorization`. Role files are absent.
- Repairs the manual-connection regression introduced by 0.14.5's silent Keychain adapter: the remote editor now exposes explicit authorization and retries discovery only after successful access.
- Background operations share a fail-fast gate with explicit authorization, so they cannot inherit its interactive setting or wait on its system dialog. Cancelled/stale results cannot reach discovery. Session keys are memory-only and invalidated by replacement/deletion.
- 93 tests / 11 suites passed, including eight new regressions with synthetic credentials. Native build/install verification is recorded in the operational note once complete.
- The system authorization dialog belongs to the user. Actual approval of their stored key is not claimed by fixture tests. No published release asset is overwritten.
- Procedure/rollback: `docs/engineering/operations/youzi-keychain-authorization.md`.
