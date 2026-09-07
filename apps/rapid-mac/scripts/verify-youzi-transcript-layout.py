#!/usr/bin/env python3
"""Run opt-in native transcript QA in an externally bounded, owned child.

Compile the release tests first with `swift test -c release`. This probe uses
--skip-build and opens no microphone or model service. A MainActor timeout task
cannot catch a main-thread layout loop, so the parent enforces the deadline.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import signal
import subprocess


def stop_owned_group(child: subprocess.Popen) -> None:
    # Only the new session created below, never an application/port name sweep.
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=int, default=60, help='Deadline in seconds (10–600)')
    parser.add_argument('--configuration', choices=('debug', 'release'), default='release')
    args = parser.parse_args()
    if not 10 <= args.timeout <= 600:
        parser.error('--timeout must be between 10 and 600 seconds')
    package = Path(__file__).resolve().parents[1]
    env = dict(os.environ, RAPID_DESKTOP_NO_PORT_SWEEP='1', YOUZI_TRANSCRIPT_LAYOUT_QA='1')
    command = ['swift', 'test', '--package-path', str(package), '-c', args.configuration,
               '--skip-build', '--filter', 'YouziSimpleTranscriptLayoutTests']
    with subprocess.Popen(command, env=env, start_new_session=True) as child:
        try:
            return child.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            print(f'Transcript layout QA timed out after {args.timeout}s.', flush=True)
            stop_owned_group(child)
            return 124
        except KeyboardInterrupt:
            stop_owned_group(child)
            return 130


if __name__ == '__main__':
    raise SystemExit(main())
