"""Opt-in synthetic HTTP voice-chain probe; never opens a microphone.

Uses already-running ASR/LLM and the candidate PCM endpoint, no downloads or
model lifecycle requests. Does not validate native playback or acoustic AEC.
Authorization can be supplied via YOUZI_PROBE_API_KEY (never saved to output).
"""

import argparse
import asyncio
import io
import json
import os
import re
import time
import wave
from pathlib import Path

import httpx


def wav_bytes(pcm):
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(24000)
        wav.writeframes(pcm)
    return output.getvalue()


async def run(args):
    args.output.mkdir(parents=True, exist_ok=True)
    headers = {}
    if token := os.environ.get("YOUZI_PROBE_API_KEY"):
        headers["Authorization"] = f"Bearer {token}"
    async with httpx.AsyncClient(
        timeout=120, trust_env=False, headers=headers
    ) as client:
        # Synthetic public-domain subject only; no device capture/user files.
        utterance = "请介绍静夜思，并解释这首诗的含义。"
        source = await client.post(
            args.tts_base + "/v1/audio/speech",
            json={
                "model": args.tts_model,
                "input": utterance,
                "stream": True,
                "response_format": "pcm",
            },
        )
        source.raise_for_status()
        source_wav = wav_bytes(source.content)
        (args.output / "input.wav").write_bytes(source_wav)
        start = time.perf_counter()
        transcription = await client.post(
            args.chat_base + "/v1/audio/transcriptions",
            data={"model": args.asr_model, "language": "zh"},
            files={"file": ("synthetic.wav", source_wav, "audio/wav")},
        )
        transcription.raise_for_status()
        text = transcription.json()["text"]
        result = {
            "utterance": utterance,
            "transcript": text,
            "asr_seconds": time.perf_counter() - start,
            "scope": "synthetic HTTP chain, NOT native UI/playback/AEC",
            "segments": [],
            "llm_text": "",
        }
        queue = asyncio.Queue(maxsize=64)
        llm_start = time.perf_counter()
        result["first_text_seconds"] = None
        result["first_pcm_seconds"] = None
        complete_at = None
        pcm_parts = []

        async def speak():
            while (sentence := await queue.get()) is not None:
                segment_start = time.perf_counter()
                sizes, arrivals = [], []
                async with client.stream(
                    "POST",
                    args.tts_base + "/v1/audio/speech",
                    json={
                        "model": args.tts_model,
                        "input": sentence,
                        "stream": True,
                        "response_format": "pcm",
                    },
                ) as response:
                    response.raise_for_status()
                    assert response.headers.get("x-audio-format") == "pcm_s16le"
                    async for chunk in response.aiter_raw():
                        if not chunk:
                            continue
                        now = time.perf_counter()
                        if result["first_pcm_seconds"] is None:
                            result["first_pcm_seconds"] = now - llm_start
                            result["first_pcm_before_llm_complete"] = (
                                complete_at is None
                            )
                        sizes.append(len(chunk))
                        arrivals.append(now - segment_start)
                        pcm_parts.append(chunk)
                result["segments"].append(
                    {
                        "text": sentence,
                        "chunk_count": len(sizes),
                        "first_pcm_seconds": arrivals[0] if arrivals else None,
                        "total_seconds": time.perf_counter() - segment_start,
                        "audio_seconds": sum(sizes) / 48000,
                    }
                )

        async with asyncio.TaskGroup() as group:
            group.create_task(speak())
            pending = ""
            async with client.stream(
                "POST",
                args.chat_base + "/v1/responses",
                json={
                    "model": args.chat_model,
                    "stream": True,
                    "store": False,
                    "input": text
                    + " 请用中文讲解六到八句话，直接回答，不要标题、Markdown或工具。",
                    "max_output_tokens": 640,
                },
            ) as response:
                response.raise_for_status()
                async for line in response.aiter_lines():
                    if not line.startswith("data: {"):
                        continue
                    event = json.loads(line[6:])
                    if event.get("type") == "response.output_text.delta":
                        delta = event.get("delta", "")
                        if delta and result["first_text_seconds"] is None:
                            result["first_text_seconds"] = (
                                time.perf_counter() - llm_start
                            )
                        result["llm_text"] += delta
                        pending += delta
                        while match := re.search(r"[。！？!?；;\n]", pending):
                            sentence, pending = (
                                pending[: match.end()],
                                pending[match.end() :],
                            )
                            if sentence.strip():
                                await queue.put(sentence.strip())
                    elif event.get("type") == "response.completed":
                        complete_at = time.perf_counter()
                    elif event.get("type") in {"response.failed", "error"}:
                        raise RuntimeError(event)
            if pending.strip():
                await queue.put(pending.strip())
            await queue.put(None)
        result["llm_complete_seconds"] = (
            complete_at - llm_start if complete_at is not None else None
        )
        result["total_chain_seconds"] = time.perf_counter() - start
        pcm = b"".join(pcm_parts)
        result["output_audio_seconds"] = len(pcm) / 48000
        (args.output / "reply.wav").write_bytes(wav_bytes(pcm))
        # Actual function-call + output round trip, deliberately read-only fixture.
        tool = {
            "type": "function",
            "name": "read_probe_status",
            "description": "Read a synthetic probe status fixture; no side effects.",
            "parameters": {
                "type": "object",
                "properties": {},
                "additionalProperties": False,
            },
        }
        prompt = "调用 read_probe_status 查询测试状态，然后用一句简短中文说明状态。"
        call = await client.post(
            args.chat_base + "/v1/responses",
            json={
                "model": args.chat_model,
                "input": prompt,
                "store": False,
                "tools": [tool],
                "tool_choice": {"type": "function", "name": tool["name"]},
                "max_output_tokens": 256,
            },
        )
        call.raise_for_status()
        calls = [
            item for item in call.json()["output"] if item["type"] == "function_call"
        ]
        assert len(calls) == 1 and calls[0]["name"] == tool["name"]
        json.loads(calls[0]["arguments"])
        history = [
            {"role": "user", "content": prompt},
            *call.json()["output"],
            {
                "type": "function_call_output",
                "call_id": calls[0]["call_id"],
                "output": json.dumps({"status": "ready", "pending_tasks": 0}),
            },
        ]
        followup = await client.post(
            args.chat_base + "/v1/responses",
            json={
                "model": args.chat_model,
                "input": history,
                "store": False,
                "tools": [tool],
                "tool_choice": "none",
                "max_output_tokens": 256,
            },
        )
        followup.raise_for_status()
        result["function_roundtrip"] = {
            "function_name": calls[0]["name"],
            "status": followup.json().get("status"),
            "text": "".join(
                part.get("text", "")
                for item in followup.json().get("output", [])
                for part in item.get("content", [])
            ),
            "scope": "synthetic read-only tool, NOT native tool approval/persistence",
        }
        (args.output / "results.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2)
        )
        print(json.dumps(result, ensure_ascii=False, indent=2))
        assert result["first_pcm_before_llm_complete"], "No overlap observed"
        assert complete_at is not None and pcm and text
        assert result["function_roundtrip"]["status"] == "completed"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chat-base", default="http://127.0.0.1:8000")
    parser.add_argument("--tts-base", default="http://127.0.0.1:18008")
    parser.add_argument("--chat-model", default="qwen3.8-27b-4bit")
    parser.add_argument("--tts-model", default="qwen3-tts")
    parser.add_argument("--asr-model", default="whisper-large-v3-turbo")
    parser.add_argument("--output", type=Path, required=True)
    asyncio.run(run(parser.parse_args()))
