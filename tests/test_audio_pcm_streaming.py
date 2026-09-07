"""Hermetic opt-in PCM streaming, thread ownership and disconnect regression tests."""

import asyncio
import threading
import time
from types import SimpleNamespace

import numpy as np
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from vllm_mlx.api.models import AudioSpeechRequest
from vllm_mlx.audio.tts import AudioOutput, TTSEngine
from vllm_mlx.routes._audio_streaming import PCMStreamingResponse
from vllm_mlx.runtime.audio_worker import AudioWorkerBusyError, AudioWorkerDispatcher


def test_request_stream_opt_in_and_interval_bounds():
    assert not AudioSpeechRequest(input="hello").stream
    assert AudioSpeechRequest(input="hello", stream=True).streaming_interval == 0.32
    for interval in (0, 0.079, 1.01, float("nan"), float("inf")):
        with pytest.raises(ValueError):
            AudioSpeechRequest(input="hello", streaming_interval=interval)


def test_engine_really_requests_qwen_chunks_and_preserves_style():
    calls = []
    closed = []

    def generate(**kw):
        calls.append(kw)
        try:
            yield SimpleNamespace(audio=np.ones(8), sample_rate=24000)
            yield SimpleNamespace(audio=np.zeros(8), sample_rate=24000)
        finally:
            closed.append(True)

    engine = TTSEngine("mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16")
    engine._loaded = True
    engine.model = SimpleNamespace(generate=generate)
    iterator = engine.stream_generate(
        "你好", voice="Vivian", instruct="温柔", streaming_interval=0.16
    )
    first = next(iterator)
    assert len(first.audio) == 8
    assert not closed
    iterator.close()
    assert closed == [True]
    assert calls[0]["stream"] is True
    assert calls[0]["lang_code"] == "auto"
    assert calls[0]["streaming_interval"] == 0.16
    assert calls[0]["instruct"] == "温柔"


async def test_worker_interleaves_without_rebinding_lease_and_closes_on_owner():
    dispatcher = AudioWorkerDispatcher()
    owners = []

    def generate():
        try:
            for value in range(3):
                owners.append(threading.get_ident())
                yield value
        finally:
            owners.append(threading.get_ident())

    source = dispatcher.iterate("tts", "qwen", generate)
    assert await anext(source) == 0
    assert dispatcher.snapshot()[0]["active_requests"] == 1
    assert dispatcher.snapshot()[0]["state"] == "busy"
    with pytest.raises(AudioWorkerBusyError):
        dispatcher.begin_handoff()
    # No network backpressure can hold the worker between yields.
    assert await dispatcher.execute("stt", "whisper", "infer", lambda: 42) == 42
    await source.aclose()
    assert len(set(owners)) == 1
    assert dispatcher.snapshot()[1]["active_requests"] == 0
    dispatcher.bind(None)


async def test_cancel_during_step_drains_and_closes_before_releasing_lease():
    dispatcher = AudioWorkerDispatcher()
    started = threading.Event()
    finished = threading.Event()
    closed = threading.Event()

    def generate():
        try:
            started.set()
            time.sleep(0.12)
            finished.set()
            yield b"a"
        finally:
            closed.set()

    source = dispatcher.iterate("tts", "qwen", generate)
    request = asyncio.create_task(anext(source))
    while not started.is_set():
        await asyncio.sleep(0.001)
    request.cancel()
    await asyncio.sleep(0.01)
    request.cancel()  # repeated cancellation must not bypass worker draining
    with pytest.raises(asyncio.CancelledError):
        await request
    assert finished.is_set() and closed.is_set()
    assert dispatcher.snapshot()[0]["active_requests"] == 0
    dispatcher.bind(None)


async def test_response_closes_if_socket_fails_while_sending_first_chunk():
    closed = []

    async def source():
        try:
            yield b"ab"
            yield b"cd"
        finally:
            closed.append(True)

    iterator = source()
    response = PCMStreamingResponse(iterator, await anext(iterator))
    sends = []

    async def send(event):
        sends.append(event["type"])
        if event["type"] == "http.response.body":
            raise OSError("socket closed")

    with pytest.raises(Exception):
        await response({"type": "http", "asgi": {"spec_version": "2.4"}}, None, send)
    assert closed == [True]
    assert sends == ["http.response.start", "http.response.body"]


@pytest.fixture
def streaming_client(monkeypatch):
    from vllm_mlx.audio import probe
    from vllm_mlx.config import get_config
    from vllm_mlx.middleware.exception_handlers import install_exception_handlers
    from vllm_mlx.routes import audio
    from vllm_mlx.runtime import audio_worker as worker_module

    class FakeEngine:
        closed = 0
        fail = False
        fail_close = False

        def stream_generate(self, *args, **kwargs):
            try:
                if self.fail:
                    raise ValueError("deliberate pre-header failure")
                yield AudioOutput(np.array([0, 0.5, -0.5]), 24000, 0.001)
                yield AudioOutput(np.array([1.0, -1.0]), 24000, 0.001)
            finally:
                self.closed += 1
                if self.fail_close:
                    raise RuntimeError("stream cleanup failed")

    engine = FakeEngine()
    dispatcher = AudioWorkerDispatcher()
    monkeypatch.setattr(worker_module, "audio_worker", dispatcher)
    monkeypatch.setattr(audio, "_tts_engine", engine)
    monkeypatch.setattr(audio, "_ensure_tts_loaded_blocking", lambda model: None)
    monkeypatch.setattr(probe, "require_mlx_audio_tts", lambda: None)
    monkeypatch.setattr(get_config(), "api_key", None)
    app = FastAPI()
    app.include_router(audio.router)
    install_exception_handlers(app)
    with TestClient(app) as client:
        yield client, engine
    dispatcher.bind(None)


def test_route_pcm_bytes_and_headers(streaming_client):
    client, engine = streaming_client
    response = client.post(
        "/v1/audio/speech",
        json=dict(input="测试", model="qwen3-tts", stream=True, response_format="pcm"),
    )
    assert response.status_code == 200, response.text
    assert response.headers["x-audio-sample-rate"] == "24000"
    assert response.headers["x-audio-format"] == "pcm_s16le"
    assert response.headers["x-audio-channels"] == "1"
    assert "content-length" not in response.headers
    assert np.frombuffer(response.content, "<i2").tolist() == [
        0,
        16383,
        -16383,
        32767,
        -32767,
    ]
    assert engine.closed == 1


@pytest.mark.parametrize(
    "overrides",
    [
        dict(response_format="wav"),
        dict(sample_rate=48000),
        dict(channels=2),
        dict(model="kokoro"),
    ],
)
def test_unsupported_stream_is_explicit_not_buffered(streaming_client, overrides):
    client, engine = streaming_client
    request = dict(input="测试", model="qwen3-tts", stream=True, response_format="pcm")
    request.update(overrides)
    # Kokoro's independent dependency gate may report unavailable before
    # reaching streaming validation; use Qwen shapes for strict 400 below.
    response = client.post("/v1/audio/speech", json=request)
    assert response.status_code in ({400, 503} if overrides.get("model") else {400})
    assert engine.closed == 0


def test_startup_error_stays_json_not_http_200(streaming_client):
    client, engine = streaming_client
    engine.fail = True
    response = client.post(
        "/v1/audio/speech",
        json=dict(input="测试", model="qwen3-tts", stream=True, response_format="pcm"),
    )
    assert response.status_code == 500
    assert response.json()["error"]["code"] == "tts_generation_failed"
    assert engine.closed == 1


def test_stream_auth_not_bypassed(streaming_client, monkeypatch):
    from vllm_mlx.config import get_config

    client, engine = streaming_client
    monkeypatch.setattr(get_config(), "api_key", "test-only-key")
    response = client.post(
        "/v1/audio/speech",
        json=dict(input="测试", model="qwen3-tts", stream=True, response_format="pcm"),
    )
    assert response.status_code == 401
    assert engine.closed == 0


async def test_close_failure_keeps_failed_lane_truth():
    dispatcher = AudioWorkerDispatcher()

    class Iterator:
        def __next__(self):
            return b"pcm"

        def close(self):
            raise RuntimeError("stream cleanup failed")

    source = dispatcher.iterate("tts", "qwen", Iterator)
    assert await anext(source) == b"pcm"
    with pytest.raises(RuntimeError, match="stream cleanup failed"):
        await source.aclose()
    lane = dispatcher.snapshot()[0]
    assert lane["active_requests"] == 0
    assert lane["state"] == "failed"
    assert lane["last_error"] == "RuntimeError"  # exception details stay private
    dispatcher.bind(None)


async def test_cancelled_factory_still_closes_result_on_owner():
    dispatcher = AudioWorkerDispatcher()
    entered = threading.Event()
    release = threading.Event()
    owners = []
    closed = []

    class Iterator:
        def __next__(self):
            return b"pcm"

        def close(self):
            closed.append(threading.get_ident())

    def factory():
        owners.append(threading.get_ident())
        entered.set()
        assert release.wait(2)
        return Iterator()

    source = dispatcher.iterate("tts", "qwen", factory)
    request = asyncio.create_task(anext(source))
    try:
        deadline = time.monotonic() + 2
        while not entered.is_set():
            assert time.monotonic() < deadline
            await asyncio.sleep(0.001)
        request.cancel()
        await asyncio.sleep(0.01)
        request.cancel()
    finally:
        release.set()
    with pytest.raises(asyncio.CancelledError):
        await request
    assert closed == owners
    assert dispatcher.snapshot()[0]["active_requests"] == 0
    assert dispatcher.snapshot()[0]["state"] == "resident"
    dispatcher.bind(None)


def test_route_cleanup_failure_does_not_erase_health(streaming_client):
    from vllm_mlx.runtime.audio_worker import audio_worker

    client, engine = streaming_client
    engine.fail_close = True
    with pytest.raises(Exception, match="stream cleanup failed"):
        client.post(
            "/v1/audio/speech",
            json=dict(
                input="测试", model="qwen3-tts", stream=True, response_format="pcm"
            ),
        )
    lane = audio_worker.snapshot()[0]
    assert lane["active_requests"] == 0
    assert lane["state"] == "failed"
    assert lane["last_error"] == "RuntimeError"  # exception details stay private


def test_existing_non_qwen_python_stream_iterator_is_compatible():
    calls = []

    def generate(**kwargs):
        calls.append(kwargs)
        yield SimpleNamespace(audio=np.ones(8), sample_rate=24000)

    engine = TTSEngine("mlx-community/Kokoro-82M-bf16")
    engine._loaded = True
    engine.model = SimpleNamespace(generate=generate)
    output = list(engine.stream_generate("hello", voice="af_heart", speed=1.2))
    assert len(output) == 1
    assert len(output[0].audio) == 8
    assert calls == [dict(text="hello", voice="af_heart", speed=1.2)]
