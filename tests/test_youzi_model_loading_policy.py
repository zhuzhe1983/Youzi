"""Preferred-pool routing is shared, exact, live-updatable and never loads weights."""

from types import SimpleNamespace

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from vllm_mlx.config import get_config
from vllm_mlx.runtime.model_loading_policy import (
    ENV_KEY, initial_pool, is_ready, resolve_request_model,
)
from vllm_mlx.runtime.model_registry import ModelEntry, ModelRegistry


@pytest.fixture
def configured(monkeypatch):
    cfg = get_config()
    registry = ModelRegistry()
    for scene in ("chat", "image", "video"):
        for suffix in ("a", "b"):
            alias = f"{scene}-{suffix}"
            engine = SimpleNamespace(is_image_gen=scene == "image", is_video_gen=scene == "video", model_name=alias)
            registry.add(ModelEntry(engine=engine, model_name=alias, model_path=f"local/{alias}", aliases=[alias]))
    monkeypatch.setattr(cfg, "automatic_model_pool", {scene: [f"{scene}-cold", f"{scene}-b", f"{scene}-a"] for scene in ("chat", "image", "video")})
    monkeypatch.setattr(cfg, "model_registry", registry)
    monkeypatch.setattr(cfg, "engine", registry.get_engine("chat-a"))
    monkeypatch.setattr(cfg, "model_name", "chat-a")
    monkeypatch.setattr(cfg, "api_key", "test-only-key")
    monkeypatch.setattr(cfg, "residency_manager", None)
    return cfg


@pytest.mark.parametrize("scene", ["chat", "image", "video"])
def test_ready_pool_member_wins_over_cold_first_and_unrelated_primary(configured, scene):
    pool = {key: list(value) for key, value in configured.automatic_model_pool.items()}
    assert resolve_request_model(None, scene) == f"{scene}-b"
    assert resolve_request_model("default", scene) == f"{scene}-b"
    assert resolve_request_model(f"{scene}-a", scene) == f"{scene}-a"
    assert configured.automatic_model_pool == pool


@pytest.mark.parametrize("requested,scene", [("chat-cold", "chat"), ("typo", "image"), ("chat-a", "video"), ("image-a", "chat"), ("gpt-unknown", "chat")])
def test_explicit_requests_never_substitute_or_load(configured, requested, scene):
    before = configured.model_registry.list_model_names()
    with pytest.raises(HTTPException) as caught:
        resolve_request_model(requested, scene)
    assert caught.value.status_code == 409
    assert caught.value.detail["error"]["code"] == "model_not_ready"
    assert configured.model_registry.list_model_names() == before


def test_empty_pool_never_resurrects_a_legacy_default(configured):
    configured.automatic_model_pool = {}
    with pytest.raises(HTTPException) as caught:
        resolve_request_model(None, "chat")
    assert caught.value.detail["error"]["code"] == "automatic_model_not_ready"
    assert resolve_request_model("chat-a", "chat") == "chat-a"


def test_standalone_cli_contract_is_unchanged(configured):
    configured.automatic_model_pool = None
    for value in (None, "", "default", "any-explicit-alias"):
        assert resolve_request_model(value, "speech") == value


def test_audio_uses_real_lane_readiness_and_alias_equivalence(configured, monkeypatch):
    from vllm_mlx.runtime.audio_worker import audio_worker
    from vllm_mlx.routes.audio import TTS_MODEL_ALIASES, STT_MODEL_ALIASES, _resolve_tts_model, _resolve_stt_model
    tts = next(iter(TTS_MODEL_ALIASES))
    stt = next(iter(STT_MODEL_ALIASES))
    configured.automatic_model_pool = {"speech": ["cold-tts", tts], "transcription": [stt]}
    lanes = [{"lane": "tts", "model": TTS_MODEL_ALIASES[tts], "state": "resident"},
             {"lane": "stt", "model": STT_MODEL_ALIASES[stt], "state": "resident"}]
    monkeypatch.setattr(audio_worker, "snapshot", lambda: lanes)
    # Use a registered alias whose profile supplies the same path.
    from vllm_mlx.audio.registry import resolve_audio_alias
    assert resolve_audio_alias(tts).hf_id == TTS_MODEL_ALIASES[tts]
    assert resolve_request_model(None, "speech") == tts
    assert _resolve_tts_model(None) == TTS_MODEL_ALIASES[tts]
    assert resolve_request_model(None, "transcription") == stt
    assert _resolve_stt_model("default") == STT_MODEL_ALIASES[stt]
    # Pure alias/voice discovery must still work before an explicit load.
    assert _resolve_tts_model("unloaded/repo") == "unloaded/repo"
    lanes[0]["state"] = "loading"
    assert not is_ready(tts, "speech")
    with pytest.raises(HTTPException):
        resolve_request_model(None, "speech")


def test_image_and_video_engine_entry_points_follow_pool(configured):
    from vllm_mlx.routes.images import _image_engine
    from vllm_mlx.routes.video import _video_engine
    assert _image_engine().model_name == "image-b"
    assert _image_engine("image-a").model_name == "image-a"
    assert _video_engine().model_name == "video-b"
    with pytest.raises(HTTPException):
        _video_engine("chat-a")


@pytest.mark.parametrize("preferred", [[], ["video-cold"], ["video-b"]])
def test_video_capabilities_honor_explicit_resident_choice(configured, preferred):
    from vllm_mlx.routes.video import router

    configured.automatic_model_pool = {"video": preferred}
    app = FastAPI()
    app.include_router(router)
    client = TestClient(app)
    headers = {"Authorization": "Bearer test-only-key"}
    before = configured.model_registry.list_model_names()
    response = client.get("/v1/videos/capabilities", params={"model": "video-a"}, headers=headers)
    assert response.status_code == 200
    assert response.json()["model"] == "video-a"
    automatic = client.get("/v1/videos/capabilities", headers=headers)
    if "video-b" in preferred:
        assert automatic.status_code == 200
        assert automatic.json()["model"] == "video-b"
    else:
        assert automatic.status_code == 409
        assert automatic.json()["detail"]["error"]["code"] == "automatic_model_not_ready"
    rejected = client.get("/v1/videos/capabilities", params={"model": "video-cold"}, headers=headers)
    assert rejected.status_code == 409
    assert rejected.json()["detail"]["error"]["code"] == "model_not_ready"
    assert configured.model_registry.list_model_names() == before
    assert configured.automatic_model_pool == {"video": preferred}


@pytest.mark.parametrize("payload,expected", [
    ('{"automatic":{"chat":["b","a"],"speech":[]}}', {"chat": ["b", "a"], "speech": []}),
    ('{"automatic":{}}', {}),
    ('{"automatic":{"typo":[]}}', {}),
    ('{"automatic":{"chat":[""]}}', {}),
    ('{"automatic":{"chat":["a","a"]}}', {}),
    ('{"automatic":{"chat":"a"}}', {}),
    ('{"automatic":{"chat":[4]}}', {}),
    ('{"automatic":{"chat":["default"]}}', {}),
    ('garbage', {}),
])
def test_spawn_policy_is_validated_and_bad_config_fails_closed(monkeypatch, payload, expected):
    monkeypatch.setenv(ENV_KEY, payload)
    assert initial_pool() == expected
    monkeypatch.delenv(ENV_KEY)
    assert initial_pool() is None


def test_authenticated_policy_save_applies_live_without_touching_registry(configured, monkeypatch):
    from vllm_mlx.routes.residency import router
    app = FastAPI()
    app.include_router(router)
    monkeypatch.setenv("YOUZI_ALLOW_ANONYMOUS_INFERENCE", "1")
    client = TestClient(app, base_url="http://localhost", client=("127.0.0.1", 23456))
    payload = {"automatic": {"chat": ["chat-a"], "image": []}}
    before = configured.model_registry.list_model_names()
    assert client.put("/v1/service/model-policy", json=payload).status_code == 401
    headers = {"Authorization": "Bearer test-only-key"}
    assert client.put("/v1/service/model-policy", json=payload, headers=headers).json() == payload
    assert resolve_request_model(None, "chat") == "chat-a"
    assert configured.model_registry.list_model_names() == before
    for bad in ({"automatic": {"bad-scene": []}}, {"automatic": {"chat": ["a", "a"]}}, {"automatic": {}, "approved": True}):
        assert client.put("/v1/service/model-policy", json=bad, headers=headers).status_code == 422
        assert configured.automatic_model_pool == payload["automatic"]


@pytest.mark.parametrize("path", ["/v1/chat/completions", "/v1/responses"])
def test_openai_route_selects_exact_preferred_engine_before_inference(configured, monkeypatch, path):
    from vllm_mlx.routes import chat, responses
    module = chat if path.endswith("completions") else responses
    captured = []
    def capture(name):
        captured.append(name)
        raise HTTPException(418, "test engine boundary")
    monkeypatch.setattr(module, "get_engine", capture)
    app = FastAPI()
    app.include_router(module.router)
    client = TestClient(app)
    headers = {"Authorization": "Bearer test-only-key"}
    prompt = {"messages": [{"role": "user", "content": "hello"}]} if module is chat else {"input": "hello"}
    # Keep protocol schema unchanged: SDK callers may use the established
    # default sentinel. Explicit aliases are never rewritten to the primary.
    for model, wanted in [("default", "chat-b"), ("chat-a", "chat-a")]:
        result = client.post(path, json={**prompt, "model": model}, headers=headers)
        assert result.status_code == 418, result.text
        assert captured[-1] == wanted
    assert client.post(path, json={**prompt, "model": "gpt-unknown"}, headers=headers).status_code in (404, 409)
    assert captured == ["chat-b", "chat-a"]


def test_responses_metadata_reports_selected_model_not_primary(configured):
    from vllm_mlx.runtime.model_loading_policy import reported_model_name
    assert reported_model_name("chat-b", "chat-a") == "chat-b"
    configured.automatic_model_pool = None
    assert reported_model_name("gpt-compat", "chat-a") == "chat-a"


@pytest.mark.asyncio
async def test_voice_discovery_uses_pool_and_allows_explicit_cold_metadata(configured, monkeypatch):
    from vllm_mlx.routes import audio
    from vllm_mlx.runtime.audio_worker import audio_worker

    alias = next(iter(audio.TTS_MODEL_ALIASES))
    configured.automatic_model_pool = {"speech": [alias]}
    lanes = [{"lane": "tts", "model": audio.TTS_MODEL_ALIASES[alias], "state": "busy"}]
    monkeypatch.setattr(audio_worker, "snapshot", lambda: lanes)
    monkeypatch.setattr("vllm_mlx.audio.probe.require_mlx_audio_tts", lambda: None)
    monkeypatch.setattr(audio, "_served_tts_default", lambda: "wrong-primary")
    monkeypatch.setattr(audio, "_allowed_voices_for", lambda model: [model])
    assert resolve_request_model(None, "speech") == alias
    assert await audio.list_voices(model=None) == {"voices": [alias]}
    assert await audio.list_voices(model="default") == {"voices": [alias]}
    lanes.clear()
    assert await audio.list_voices(model="unloaded/repo") == {"voices": ["unloaded/repo"]}
    with pytest.raises(HTTPException) as error:
        await audio.list_voices(model=None)
    assert error.value.status_code == 409


@pytest.mark.asyncio
async def test_streaming_speech_rechecks_after_lane_lock_without_loading(configured, monkeypatch):
    from contextlib import asynccontextmanager
    from vllm_mlx.routes import audio
    from vllm_mlx.runtime.audio_worker import audio_worker

    model = "local/tts"
    configured.automatic_model_pool = {"speech": [model]}
    lanes = [{"lane": "tts", "model": model, "state": "resident"}]
    monkeypatch.setattr(audio_worker, "snapshot", lambda: lanes)
    assert resolve_request_model(None, "speech") == model

    @asynccontextmanager
    async def retired_while_waiting():
        lanes.clear()
        yield

    monkeypatch.setattr(audio, "_get_tts_lane_lock", retired_while_waiting)
    monkeypatch.setattr(audio, "_ensure_tts_loaded_blocking", lambda *_: pytest.fail("Must not reload a retired model"))
    stream = audio._stream_speech_pcm(model, "hello", {}, 0.3)
    with pytest.raises(HTTPException) as error:
        await anext(stream)
    assert error.value.status_code == 409
    await stream.aclose()


def test_responses_default_works_with_singleton_without_registry(configured, monkeypatch):
    from vllm_mlx.routes import responses

    configured.model_registry = None
    configured.automatic_model_pool = {"chat": ["chat-a"]}
    captured = []

    def capture(name):
        captured.append(name)
        raise HTTPException(418, "test engine boundary")

    monkeypatch.setattr(responses, "get_engine", capture)
    app = FastAPI()
    app.include_router(responses.router)
    client = TestClient(app)
    result = client.post("/v1/responses", json={"model": "default", "input": "hello"},
                         headers={"Authorization": "Bearer test-only-key"})
    assert result.status_code == 418, result.text
    assert captured == ["chat-a"]


@pytest.mark.parametrize("path", [
    "/v1/completions", "/v1/messages", "/v1/messages/count_tokens",
])
def test_other_text_routes_use_same_exact_pool(configured, monkeypatch, path):
    from vllm_mlx.routes import anthropic, completions

    module = completions if path == "/v1/completions" else anthropic
    captured = []

    def capture(name=None):
        captured.append(name)
        raise HTTPException(418, "test engine boundary")

    monkeypatch.setattr(module, "get_engine", capture)
    app = FastAPI()
    app.include_router(module.router)
    client = TestClient(app)
    headers = {"Authorization": "Bearer test-only-key"}
    prompt = ({"prompt": "hello"} if module is completions else
              {"messages": [{"role": "user", "content": "hello"}], "max_tokens": 4})
    for model, wanted in [("default", "chat-b"), ("chat-a", "chat-a")]:
        result = client.post(path, json={**prompt, "model": model}, headers=headers)
        assert result.status_code == 418, result.text
        assert captured[-1] == wanted
    for model in ("gpt-unknown", "claude-unknown", "chat-cold", "image-a"):
        result = client.post(path, json={**prompt, "model": model}, headers=headers)
        assert result.status_code == 409, result.text
    assert captured == ["chat-b", "chat-a"]
    configured.automatic_model_pool = {}
    result = client.post(path, json={**prompt, "model": "default"}, headers=headers)
    assert result.status_code == 409, result.text
    assert captured == ["chat-b", "chat-a"]


def test_count_tokens_without_model_uses_pool_not_primary(configured, monkeypatch):
    from vllm_mlx.routes import anthropic

    captured = []

    def capture(name=None):
        captured.append(name)
        raise HTTPException(418, "test engine boundary")

    monkeypatch.setattr(anthropic, "get_engine", capture)
    app = FastAPI()
    app.include_router(anthropic.router)
    client = TestClient(app)
    result = client.post(
        "/v1/messages/count_tokens",
        json={"messages": [{"role": "user", "content": "hello"}]},
        headers={"Authorization": "Bearer test-only-key"},
    )
    assert result.status_code == 418, result.text
    assert captured == ["chat-b"]
