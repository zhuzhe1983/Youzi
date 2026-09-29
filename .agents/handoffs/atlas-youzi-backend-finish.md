# Backend baseline repair — 2026-09-30

Owner: Vector/Atlas, Local Mac. Receiving owner: Atlas integration.
Branch: `atlas/youzi-backend-finish-20260930`, based on `f0ad132c`.
Role files are absent from this checkout. Work uses a separate Git worktree.

## Outcome

The three inherited failures recorded in
[the integration audit](../../docs/engineering/operations/2026-09-15-youzi-integration-verification.md)
were reproduced and resolved without changing production model math, relaxing
numeric tolerances, removing assertions, or loading real model weights.

### Float32 cache parity

MLX's default M5 tensor operations use reduced precision for some float32
matrix-matrix operations while the single-row matrix-vector path retains full
precision. Thus prefill and incremental decode were testing different effective
arithmetic despite both arrays reporting `float32`. This behavior and the
`MLX_ENABLE_TF32=0` process setting are documented in
[MLX's numerical precision guide](https://ml-explore.github.io/mlx/build/html/usage/precision.html).
The installed MLX 0.32.2 binary contains and honors this setting.

A seed-0 synthetic comparison on the same evaluated weights isolated the issue:

| Comparison | GPU default | CPU | GPU, `MLX_ENABLE_TF32=0` |
| --- | ---: | ---: | ---: |
| Batched vs rowwise `(1,24,64) @ (64,64)` | 0.0215092 | 0.000007629 | 0.000008583 |
| Bailing, full vs cached token decode | 0.00992128 | 0.000002742 | 0.000003338 |
| Muse, full vs cached token decode | 0.00302446 | 0.000002261 | 0.000001155 |

Values are maximum absolute differences, not speed or real-model quality claims.
The tests' original `2e-3` thresholds remain unchanged. Seed 7 also passes with
GPU maximum differences of `3.159e-6` (Bailing) and `1.483e-6` (Muse).

`tests/conftest.py` now defaults `MLX_ENABLE_TF32` to `0` before its MLX
availability import. This must precede backend initialization because MLX caches
the setting. An explicit process environment override is preserved for testing
reduced-precision behavior. The two regression tests now each run seeds 0 and 7
so failures can be reproduced independently of prior random-number consumption.
The default production inference precision is unchanged.

### Audio lane discovery

The old helper mounted only the models router on a fresh app, but the production
discovery predicate correctly inspects the canonical audio-registration sentinel
on `server.app`. The fixture never mounted audio there. An earlier test could
leave the global app registered, explaining why the broad run passed while the
isolated test returned `audio_lanes: null`.

The helper now monkeypatches `server.app` to its own fresh app and explicitly
registers canonical audio routes when requested. The regression asserts the
recorded `stt: degraded` / `tts: ok` snapshot when mounted and `null` when
unmounted. The no-probe test runs with audio mounted, ensuring its `null` result
is due to absent probe data rather than an accidental route gate. Monkeypatch
restores the process-global app after each test.

## Verification

Environment: Apple M5 Max, arm64, macOS 27.0 (26A428), Python 3.12.13,
MLX 0.32.2, mlx-lm 0.31.3, NumPy 2.5.2, pytest 9.1.1,
pytest-asyncio 1.4.0, FastAPI 0.141.1, httpx 0.28.1, Ruff 0.16.6.
Dependencies came read-only from the existing delivery virtualenv. `PYTHONPATH`
selected this checkout. Repository network/cache/config isolation was active.

- Original three nodes before repair: 3 failures.
- Model suites with external full-float32 setting, before fixture changes:
  27 passed, 1 skipped.
- Four focused suites after repair: 84 passed, 1 skipped.
- Audio lane regression alone in a fresh process: 2 passed, covering both
  registration states.
- Combined regression below: 771 passed, 13 skipped (784 collected).
- Ruff on all four changed Python files: passed.
- `git diff --check`: passed.

The Muse fallback test skips because this environment now has native
`mlx_vlm.models.muse_glimmer` support; the fallback is deliberately conditional.
Other skipped cases are existing dependency/optional-backend cases. Counts
overlap and must not be added together.

Set `TEST_PYTHON` to the existing test interpreter and run from the checkout:

```sh
PYTHONPATH="$PWD" PYTHONDONTWRITEBYTECODE=1 "$TEST_PYTHON" -B -m pytest -q \
  tests/test_bailing_hybrid_model.py tests/test_muse_glimmer_model.py \
  tests/test_audio_routes_bundle.py tests/test_audio_route_registration_gate.py

PYTHONPATH="$PWD" PYTHONDONTWRITEBYTECODE=1 "$TEST_PYTHON" -B -m pytest -q \
  tests/test_audio_routes_bundle.py::TestDeepProbeSurfacesDegradedLane::test_models_endpoint_surfaces_lane_status

PYTHONPATH="$PWD" PYTHONDONTWRITEBYTECODE=1 "$TEST_PYTHON" -B - <<'PY'
from pathlib import Path
import pytest
files = sorted(str(p) for p in Path('tests').glob('test_*.py') if 'audio' in p.name)
files += [
    'tests/test_bailing_hybrid_model.py', 'tests/test_muse_glimmer_model.py',
    'tests/test_mlx_compat.py', 'tests/test_muse_parsers.py',
    'tests/test_capabilities_field.py', 'tests/test_routes.py',
]
raise SystemExit(pytest.main([
    '-q', '-m',
    'not requires_network and not real_hf_cache and not slow and not integration and not needle',
    *files,
]))
PY
```

For the primitive diagnosis, run this in separate processes with
`MLX_ENABLE_TF32=1` and `MLX_ENABLE_TF32=0`; conftest is not involved:

```python
import mlx.core as mx
mx.random.seed(0)
x = mx.random.normal((1, 24, 64))
w = mx.random.normal((64, 64))
mx.eval(x, w)
full = x @ w.T
step = mx.concatenate([x[:, i:i+1] @ w.T for i in range(24)], axis=1)
print(mx.max(mx.abs(full - step)).item())
```

## Integration handoff

No backend blocker remains in this scope. Atlas should include this commit in
the integration candidate, run the aggregate verification with the other
workstreams, push the integrated result, and perform authorized recoverable
worktree cleanup. No services were restarted and no real-model inference,
dependency upgrades, production deployment, or physical audio acceptance ran.
Default reduced-precision production output differences are an upstream MLX
behavior; these tests specifically verify full-float32 architectural parity.
