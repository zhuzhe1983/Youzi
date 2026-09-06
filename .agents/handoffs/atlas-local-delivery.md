# Atlas → Atlas / Harbor: Youzi local delivery

- Date: 2026-09-06; owner Atlas on Local Mac. This task depends on the existing
  application worktree, not the older nominal main worktree. `AGENTS.md` read;
  `.agents/roles/` is absent, so no role file was available.
- Branch: `atlas/youzi-local-delivery`, based on `b03d22c4` (the reviewed loaded-only,
  rich OpenAI model-discovery change). No remote-main merge was performed.
- Documentation `ca2d5494`: Youzi positioning and hardware guidance, original
  README archived byte-for-byte from `def79da6`, local/GitHub delivery runbook.
- Application `dd204d6f`: preserve and commit the existing local workspace,
  experts/skills/connectors, task/data/security, model settings/defaults/tray,
  personalization/i18n/font and live-auth work; regression coverage included.
  Updated two stale source-contract tests without dropping their assertions,
  and used the POSIX formatter for time-zone abbreviation independence.
- CI: scoped Apple Silicon compilation/tests and manual full runtime packaging
  with optional draft-only release. No public release, tag or production deploy
  was requested/executed for this delivery. Static actionlint passed for the new
  workflows; inherited workflow lint requires ignoring its existing custom
  `rapidmlx-studio` runner-label warning. Hosted run results are separate evidence.

## Verified facts

- Release executable compiled in 93.10 seconds on this Local Mac; app metadata
  0.14.1 (171). This is a build duration, not an inference benchmark.
- App fully reassembled, verified fallback runtime restored, reviewed auth,
  residency and discovery modules updated in both fallback and active override.
  Baseline sourceless bytecode checked before patching. Existing installed image
  and video routes were independently found identical to current source.
- Both runtime imports passed for Qwen Image, Flux2 text/edit and Z-Image without
  importing torch/cv2/matplotlib. This is not real image-generation validation.
- Framework rpaths and deep/strict code signatures passed. Bundle was reopened;
  app and engine survived more than 60 seconds; `/health` is ready with loaded
  `rapid-mlx/Qwen3.8-27B-4bit-MTP-MLX`.
- Official OpenAI SDK 3.8.0 strict live list/retrieve checks passed. Listing has
  two entries (canonical ID plus alias), retains extensions and `owned_by=youzi`.
- Real model Responses: non-streaming returned `YOUZI_OK`; streaming returned
  `STREAM_OK` with completed status and matching collected output.
- Native Settings: address shows port 8000 without punctuation. Changing to key
  required and pressing Save changed anonymous discovery to 401; allowing anonymous
  requests and pressing Save changed it back to 200. Backend PID unchanged.
  Restored the user's original anonymous setting. Wrong key, browser Origin and
  anonymous management requests still yield 401. No credentials were logged.
- Current focused Swift CI selection: **124 tests / 26 suites passed**. Additional
  product selection: 110 / 16; auth/settings selection: 71 / 13 (overlapping,
  do not sum these counts). Python auth/discovery/import tests: **44 passed**.
- Earlier isolated committed API regression: **1480 passed, 14 skipped**; see
  `atlas-loaded-model-discovery.md` for scope and qualifications.
- README archive SHA-256:
  `483020c929d3ca6ba89e2f9d7214b178a50bb8a078d070e31e67990e151f1b54`.

## Failures, limits and next actions

- The initial full Swift run was **not green**: stale source contracts, locale
  dependence and subprocess/UI timing failures. That run also invoked a real
  port sweep which stopped the existing engine. The service was restored with
  the new package. All subsequent runs used `RAPID_DESKTOP_NO_PORT_SWEEP=1`.
  Stale/locale failures were fixed; affected timing suites passed when separated,
  except three capability-probe cases which required individual runs to pass.
  Do not claim a passing full concurrent suite or increase timeouts blindly.
- This package reuses the verified runtime and patches reviewed changed modules;
  a full clean sidecar rebuild, hosted package run, real image/video/voice
  generation, and Apple signing/notarization remain separately unverified.
- Historical broader goals are not implied complete: bundle identity still uses
  the inherited domain; strict-key Agent adapter discovery propagation and the
  simple-chat context estimate remain preexisting limitations.
- Full app/runtime and dirty-source backups were preserved outside the repository.
  `.butler/` and `.wip-stash/` remain local and are excluded from commits.
- Receiving Atlas: review remote changes separately now that this local batch is
  committed and testable; retain local UI behavior, integrate backend changes only
  after overlap review and regression checks. Do not fast-forward/reset over it.
- Receiving Harbor: inspect the hosted CI run after push, configure required
  reviewers for the `youzi-draft` environment, and validate a full package before
  proposing any release. The default GitHub README changes only after deliberate
  integration into main; branch push alone does not update the homepage.
