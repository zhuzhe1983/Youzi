# Youzi 0.14.6 image request preflight

- Receiving owner: Atlas; implementation: delegated desktop workstream.
- Branch: `fix/youzi-0146-desktop`, following desktop commit `70fd6f1de`.
- Upstream reference: `8f076c1971ac9a645c3a2ef13365cf32ae037a58` (#4573).
- Host: Local Mac, arm64, Python 3.12.13 from the task test environment.
- Goal: reject invalid image requests before weight loading, while retaining Youzi's worker ownership, request controls, and loaded-only policy.

## Adaptation

Youzi already rejected most generation controls through `ImageParameterError` before model loading, and its image adapter uses one dedicated worker for load/render/release. The backport keeps those behaviors and closes the remaining gaps:

- Extract existing asset-independent validation into `validate_request`; invoke it before adapter worker submission and again in the backend.
- Add `ImageRequestError` as the base of the existing `ImageParameterError`, preserving existing exception compatibility and the `unsupported_image_parameters` code.
- Both generation and edit routes return HTTP 400 for request errors. Newly classified request errors use `invalid_image_request`; operational failures remain 500 and cancellation remains successful.
- HiDream token-limit failures become request errors. Youzi's tokenizer-first, weight-loading-later order is retained; tokenizer assets may still be needed for counting.
- Reject unsupported explicit image residency modes before manager admission, worker creation, and resident reuse. Wrapped request errors preserve their actionable message without exposing operational loader details.
- No server loader rewrite was necessary: its existing `ensure_resident` boundary now validates before touching assets.

No namespace migration, dependency upgrade, model alias addition, image-size parser change, Swift change, or actual inference was performed. Youzi's nearest-legal-size adjustment and notification remain in the untouched Swift tool path. The loaded-only selection policy and authentication before multipart body reads remain covered by passing regression tests.

## Verification

From this worktree root, using the task-provided Python environment and existing preview sidecar dependencies:

```sh
PYTHONPATH="$PWD:/Users/zhuzhe/Workspace/Youzi/apps/rapid-mac/build/Youzi Workspace Preview.app/Contents/Resources/rapid-mlx/site-packages" \
  /tmp/youzi-0146-test-venv/bin/python -m pytest -q \
  tests/test_image_lane.py \
  tests/test_image_worker_affinity.py \
  tests/test_image_residency_preflight.py \
  tests/test_youzi_model_loading_policy.py \
  tests/test_youzi_anonymous_inference.py \
  tests/test_residency_load_field_names.py \
  tests/test_resident_models.py
```

Result: **405 passed**. These tests use mocks/in-process transport and hermetic cache/network isolation, never real model inference.

Ruff checks passed for all eight modified/new Python source and test files; `git diff --check` passed. Logs are retained at `/tmp/youzi-0146-image-preflight-tests.log` and `/tmp/youzi-0146-image-preflight-lint.log`.

The worker mode-switch test now uses a real dual-capability family instead of pretending Z-Image supports editing. Residency tests use the current alias plus explicit edit checkpoint path because the older upstream edit alias is absent from Youzi; clocks are fixed when comparing residency state.

## Next action

Atlas should cherry-pick the independent image commit and include it in integrated release checks. No implementation blocker remains. Full production model/visual acceptance belongs to the root release task. This workstream does not merge, push, or release.
