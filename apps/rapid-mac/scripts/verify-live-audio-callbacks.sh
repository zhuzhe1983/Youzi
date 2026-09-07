#!/usr/bin/env bash
# Default: fixed production callbacks. --negative-controls additionally verifies
# that the pre-fix tap closure SIGTRAPs through the real Objective-C bridge.
# No microphone/speaker, model, service, user defaults, or port sweeping.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-fixed}"
if [[ "$MODE" != fixed && "$MODE" != --negative-controls ]]; then
    echo "usage: $0 [--negative-controls]" >&2; exit 2
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/youzi-callback-probe.XXXXXX")"
export RAPID_DESKTOP_NO_PORT_SWEEP=1
swiftc -swift-version 6 -O -g -parse-as-library \
    "$ROOT/Sources/Rapid/LiveVoice/YouziLiveAudioEngine.swift" \
    "$ROOT/Sources/Rapid/LiveVoice/YouziLiveAudioCallbacks.swift" \
    "$ROOT/scripts/verify-live-audio-callbacks.swift" -o "$OUT/probe"
python3 - "$OUT" "$MODE" <<'PY'
import pathlib, resource, signal, subprocess, sys
out = pathlib.Path(sys.argv[1])
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
modes = ['legacy-tap', 'fixed'] if sys.argv[2] == '--negative-controls' else ['fixed']
for mode in modes:
    result = subprocess.run([str(out / 'probe'), mode], capture_output=True, text=True, timeout=20)
    (out / f'{mode}.log').write_text(result.stdout + result.stderr)
    expected = -signal.SIGTRAP if mode.startswith('legacy-') else 0
    if result.returncode != expected:
        raise SystemExit(f'FAIL {mode}: exit {result.returncode}, expected {expected}; evidence {out}')
    print(f'PASS {mode}: exit {result.returncode}')
    if mode == 'fixed':
        print(result.stdout.strip())
print(f'Evidence (temporary, not committed): {out}')
PY
