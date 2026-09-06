# Youzi local delivery and GitHub packaging

## Ownership and safety

Atlas owns integration; Harbor owns workflow/rollout follow-up. Finish the local
application batch before merging upstream changes. Use a task worktree based on
the application branch when the task depends on uncommitted application work;
back up that work before changing branches. Do not force-push main, reset another
worktree, or include local transcripts, credentials, model weights or build output.

Before replacing a local app, back up **both** the entire app bundle and the
active runtime override, plus user data before schema-changing trials. Quit the
exact app normally; abort if it does not exit. The packaging script recreates the
app directory. An executable-only swap is not a valid application update.

## Local verification

Always set `RAPID_DESKTOP_NO_PORT_SWEEP=1` when testing on a development Mac:
real `ServerManager` tests can otherwise terminate the active port-8000 engine.
A full concurrent Swift Testing run is not an isolated application environment.
Use focused suites and investigate timing failures independently; do not silently
remove assertions to obtain a green full-suite result.

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac \
  --filter 'Youzi|ModelServiceAuthTests|ModelAPIAccessTests|ModelGenerationDefaultsTests|SettingsVoicePreviewTests|CustomInstructionsTests|BrowseProxyCompatibilityTests|SidecarBuildScriptTests|StreamingRowIsolationTests|CurrentDateTimeContextTests'
swift build --package-path apps/rapid-mac -c release
python -m pytest -q tests/test_youzi_anonymous_inference.py \
  tests/test_youzi_loaded_models.py tests/test_sidecar_z_image_imports.py
git diff --check
```

The Python tests require the repository test dependencies. Install the official
OpenAI SDK in the test environment to exercise the strict SDK contract test;
without it that optional check is skipped, not evidence of compatibility.

A complete package uses `bash apps/rapid-mac/scripts/build.sh`. For a deliberately
incremental local delivery, `SKIP_SIDECAR=1` requires restoring the verified runtime
and updating all changed Python modules in both the bundled fallback and active
override before re-signing. The override takes precedence over bundled Python;
changing repository `.py` files alone does not update an installed sourceless
`.pyc` runtime. Verify its baseline before patching; abort on an unexpected build.
This incremental procedure is **not** a clean-room sidecar rebuild.

Before declaring the app healthy:

- Check framework rpaths and `codesign --verify --deep --strict`.
- Confirm the app and engine remain alive for at least 60 seconds and `/health`
  reports readiness, not merely a listening socket.
- Check official SDK model list/retrieve parsing and real Responses, both
  non-streaming and streaming, against a loaded local model.
- In native Settings, Save required-key mode and observe anonymous discovery
  become 401; Save anonymous mode and observe 200 without restarting the engine.
  Restore the user's initial setting; wrong keys and management APIs stay strict.
- Never log bearer values, dump key-bearing process arguments or capture secrets
  in screenshots. Use a synthetic prompt rather than a user's conversation.

Rollback: quit the exact app, restore the complete saved app and active override,
verify signatures, and reopen. Do not delete model files or reset user settings.
A runtime/app rollback does not reverse domain schema changes: preserve user data
and use a version that understands the current schema rather than overwriting it.

## GitHub Actions

- `youzi-ci.yml`: Apple Silicon release compilation and focused Youzi regression
  suites on main, the local-delivery branch, PRs and manual dispatch. This is a
  scoped regression gate, not a claim that all inherited tests passed.
- `youzi-package.yml`: manual full app + inference-runtime packaging; no model
  weights. Verifies the app signature, uploads a ZIP and SHA-256 artifact.
- Optional `create_draft` creates a **draft only** under `youzi-v<app version>`.
  It never publishes a release, sends an updater feed or deploys to a CDN/PyPI.
  Configure required reviewers for the `youzi-draft` environment in repository
  settings before enabling the draft step. Dispatch from reviewed trusted code.
- Builds are ad-hoc signed, **not Apple-notarized**; they are local-test packages,
  not a claim of Gatekeeper-ready public distribution. Apple signing/notarization
  and public publication require separate credentials and human authorization.
- Inherited automatic engine release and PyPI build entry jobs are restricted to
  the upstream repository. Other inherited workflows remain historical; do not
  manually dispatch upstream deployment/release workflows for Youzi.
- A workflow file committed on a feature branch is configuration, not a successful
  hosted run. Manual workflows normally need to reach the default branch before
  their dispatch controls are available. Check Actions after pushing.
