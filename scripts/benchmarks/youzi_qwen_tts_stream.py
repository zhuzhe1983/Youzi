#!/usr/bin/env python3
"""Offline, isolated Qwen3-TTS PCM streaming probe (not an HTTP benchmark).

Run with a Python environment containing mlx-audio. Never accepts a Hub model
ID: --model must be a cached local directory. Writes measurements and synthetic
WAV files only to --output. The parent bounds and reaps only its own worker.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import time
import traceback
import wave
from pathlib import Path


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--model", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--device", choices=("gpu", "cpu"), default="gpu")
    p.add_argument("--interval", type=float, default=0.32)
    p.add_argument("--max-tokens", type=int, default=384)
    p.add_argument("--timeout", type=float, default=180)
    p.add_argument("--runs", type=int, default=4)
    p.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    return p


def emit(kind: str, **data) -> None:
    print(json.dumps({"event": kind, **data}, ensure_ascii=False), flush=True)


def probe(args: argparse.Namespace) -> int:
    # Device selection must precede model import/allocation. For CPU, disable
    # explicit GPU streams too: fail rather than accidentally report GPU speed.
    import importlib.metadata
    import resource

    import mlx.core as mx
    import numpy as np

    device = mx.cpu if args.device == "cpu" else mx.gpu
    mx.set_default_device(device)
    if args.device == "cpu":
        original_set_device = mx.set_default_device
        original_stream = mx.stream
        original_new_stream = mx.new_stream

        def cpu_only_set_device(value):
            if value != mx.cpu and value != mx.Device(mx.cpu):
                raise RuntimeError(f"CPU probe rejected device switch to {value}")
            return original_set_device(value)

        def cpu_only_stream(value):
            stream_device = getattr(value, "device", value)
            if stream_device != mx.cpu and stream_device != mx.Device(mx.cpu):
                raise RuntimeError(f"CPU probe rejected stream on {stream_device}")
            return original_stream(value)

        def cpu_only_new_stream(value):
            if value != mx.cpu and value != mx.Device(mx.cpu):
                raise RuntimeError(f"CPU probe rejected new stream on {value}")
            return original_new_stream(value)

        mx.set_default_device = cpu_only_set_device
        mx.stream = cpu_only_stream
        mx.new_stream = cpu_only_new_stream

    from mlx_audio.tts.utils import load_model

    emit(
        "environment",
        device=str(mx.default_device()),
        platform=platform.platform(),
        versions={
            name: importlib.metadata.version(name)
            for name in ("mlx", "mlx-audio", "numpy")
        },
        interval=args.interval,
        max_tokens=args.max_tokens,
        model_snapshot=args.model.name,
        generation_seed=42,
    )
    start = time.perf_counter()
    model = load_model(args.model)
    mx.synchronize()
    emit("loaded", seconds=time.perf_counter() - start, device=str(mx.default_device()))
    texts = [
        "你好，我是柚子。",
        "你好，我是柚子。",
        "请帮我整理今天的任务。我们先检查模型服务，然后生成一段语音旁白。",
        "床前明月光，疑是地上霜。举头望明月，低头思故乡。"
        "这是一首表达思乡之情的唐诗。我可以为它生成插图和旁白，再整理成网页。",
    ]
    for run in range(args.runs):
        text = texts[min(run, len(texts) - 1)]
        mx.random.seed(42)
        mx.synchronize()
        start = time.perf_counter()
        last = start
        first = None
        audio_seconds = 0.0
        max_gap = 0.0
        # Queue simulation: minimum additional startup buffer needed to play
        # all measured chunks continuously at natural speed, no speaker I/O.
        min_extra_buffer = 0.0
        parts = []
        chunks = []
        sample_rate = None
        emit("start", run=run, text=text)
        for result in model.generate(
            text=text,
            voice="Vivian",
            lang_code="Chinese",
            stream=True,
            streaming_interval=args.interval,
            max_tokens=args.max_tokens,
            verbose=False,
        ):
            audio = np.asarray(result.audio, dtype=np.float32).reshape(-1).copy()
            # np.asarray materializes the lazy MLX array before timestamping.
            now = time.perf_counter()
            if not audio.size:
                continue
            sr = int(result.sample_rate)
            if not np.isfinite(audio).all():
                raise RuntimeError("Nonfinite PCM")
            if sample_rate is not None and sr != sample_rate:
                raise RuntimeError("Sample rate changed during stream")
            sample_rate = sr
            elapsed = now - start
            if first is None:
                first = elapsed
            else:
                max_gap = max(max_gap, now - last)
            min_extra_buffer = max(min_extra_buffer, elapsed - first - audio_seconds)
            duration = audio.size / sr
            info = dict(
                index=len(parts),
                elapsed=elapsed,
                gap=now - last,
                duration=duration,
                samples=int(audio.size),
            )
            chunks.append(info)
            emit("chunk", run=run, **info)
            parts.append(audio)
            audio_seconds += duration
            last = now
        elapsed = time.perf_counter() - start
        if first is None or sample_rate is None:
            raise RuntimeError("No nonempty audio chunks")
        audio = np.concatenate(parts)
        with wave.open(str(args.output / f"{args.device}-{run}.wav"), "wb") as f:
            f.setnchannels(1)
            f.setsampwidth(2)
            f.setframerate(sample_rate)
            f.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
        emit(
            "result",
            run=run,
            text=text,
            device=str(mx.default_device()),
            first_pcm_seconds=first,
            total_seconds=elapsed,
            audio_seconds=audio_seconds,
            rtf=elapsed / audio_seconds,
            chunk_count=len(parts),
            max_interchunk_gap_seconds=max_gap,
            min_extra_playback_buffer_seconds=max(0.0, min_extra_buffer),
            peak_abs=float(np.max(np.abs(audio))),
            rss_peak_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
            sample_rate=sample_rate,
            chunks=chunks,
        )
    return 0


def main() -> int:
    args = parser().parse_args()
    args.model = args.model.expanduser().resolve()
    args.output = args.output.expanduser().resolve()
    if not (args.model / "config.json").is_file():
        raise SystemExit("--model must point to an existing local model directory")
    if min(args.runs, args.interval, args.timeout, args.max_tokens) <= 0:
        raise SystemExit("runs/interval/timeout/max-tokens must be positive")
    args.output.mkdir(parents=True, exist_ok=True)
    os.environ.update(
        HF_HUB_OFFLINE="1",
        TRANSFORMERS_OFFLINE="1",
        PYTHONDONTWRITEBYTECODE="1",
        TOKENIZERS_PARALLELISM="false",
    )
    if args.worker:
        try:
            return probe(args)
        except Exception as exc:
            emit("error", type=type(exc).__name__, message=str(exc))
            traceback.print_exc()
            return 1
    with (
        (args.output / f"{args.device}.jsonl").open("w") as out,
        (args.output / f"{args.device}.stderr.log").open("w") as err,
    ):
        child = subprocess.Popen(
            [sys.executable, "-B", __file__, *sys.argv[1:], "--worker"],
            stdout=out,
            stderr=err,
        )
        try:
            code = child.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            code = 124
            out.write(
                json.dumps({"event": "timeout", "limit_seconds": args.timeout}) + "\n"
            )
    emit("finished", code=code, output=str(args.output))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
