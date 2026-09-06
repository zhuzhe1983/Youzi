"""Loaded-only OpenAI discovery retains Desktop and Agent metadata on /v1/models."""

import io
from types import SimpleNamespace
from urllib.parse import urlsplit

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from vllm_mlx.config import get_config
from vllm_mlx.routes.models import router
from vllm_mlx.runtime.model_registry import ModelEntry, ModelRegistry


@pytest.fixture
def discovery(monkeypatch):
    cfg = get_config()
    for name, value in dict(
        api_key=None,
        ready=True,
        draining=False,
        engine=None,
        model_name=None,
        model_alias=None,
        model_registry=None,
        residency_manager=None,
        embedding_engine=None,
        embedding_model_locked=None,
        tool_call_parser=None,
        reasoning_parser_name=None,
    ).items():
        monkeypatch.setattr(cfg, name, value)
    app = FastAPI()
    app.include_router(router)
    return cfg, TestClient(app)


def test_empty_and_configured_but_unloaded(discovery):
    cfg, client = discovery
    cfg.model_name = "configured/not-loaded"
    cfg.model_alias = "short-alias"
    cfg.embedding_model_locked = "embedding/not-loaded"
    assert client.get("/v1/models").json() == {
        "object": "list",
        "data": [],
        "models": [],
    }


def test_live_model_and_alias_keep_standard_shape_plus_extensions(discovery):
    cfg, client = discovery
    cfg.engine = object()
    cfg.model_name = "local/chat-model"
    cfg.model_alias = "chat"
    first = client.get("/v1/models").json()
    assert first["object"] == "list"
    assert [m["id"] for m in first["data"]] == ["local/chat-model", "chat"]
    for card in first["data"]:
        assert {"id", "object", "created", "owned_by"} <= card.keys()
        assert card["object"] == "model"
        assert card["owned_by"] == "youzi"
        assert type(card["created"]) is int and card["created"] > 0
        assert {
            "context_window",
            "tool_call_parser",
            "reasoning_parser",
            "recommended_sampling",
            "capabilities",
            "modality",
            "speculative_decoding",
            "is_hybrid",
        } <= card.keys()
    assert {m["slug"] for m in first["models"]} == {"local/chat-model", "chat"}
    assert client.get("/v1/models").json() == first
    for card in first["data"]:
        assert client.get(f"/v1/models/{card['id']}").json() == card
    cfg.engine = None
    assert client.get("/v1/models").json() == {
        "object": "list",
        "data": [],
        "models": [],
    }


@pytest.mark.parametrize("flag", ["ready", "draining"])
def test_startup_and_shutdown_do_not_advertise(discovery, flag):
    cfg, client = discovery
    cfg.model_name, cfg.engine = "chat", object()
    setattr(cfg, flag, flag == "draining")
    assert client.get("/v1/models").json()["data"] == []


def test_all_modalities_residency_and_eviction(discovery):
    cfg, client = discovery
    cfg.model_registry = ModelRegistry()
    states = {}
    for name in [
        "chat",
        "voice",
        "image",
        "video",
        "registered",
        "loading",
        "evicting",
    ]:
        cfg.model_registry.add(
            ModelEntry(
                engine=SimpleNamespace(is_resident=name != "registered"),
                model_name=name,
                model_path=name,
                aliases={name, name + "-alias"},
            )
        )
        states[name] = (
            name if name in {"registered", "loading", "evicting"} else "resident"
        )
    cfg.residency_manager = SimpleNamespace(
        snapshot=lambda: {
            "models": [{"id": name, "state": state} for name, state in states.items()]
        }
    )
    expected = [
        "chat",
        "chat-alias",
        "voice",
        "voice-alias",
        "image",
        "image-alias",
        "video",
        "video-alias",
    ]
    body = client.get("/v1/models").json()
    assert [m["id"] for m in body["data"]] == expected
    assert {m["slug"] for m in body["models"]} <= set(expected)
    states["image"] = "evicting"
    states["video"] = "registered"
    body = client.get("/v1/models").json()
    assert [m["id"] for m in body["data"]] == expected[:4]
    assert {m["slug"] for m in body["models"]} <= set(expected[:4])


def test_lazy_workers_without_manager_and_embedding(discovery):
    cfg, client = discovery
    cfg.model_registry = ModelRegistry()
    lazy = SimpleNamespace(is_resident=False)
    cfg.model_registry.add(
        ModelEntry(engine=lazy, model_name="voice", model_path="voice")
    )
    cfg.embedding_model_locked = "embeddings"
    cfg.embedding_engine = SimpleNamespace(is_loaded=False)
    assert client.get("/v1/models").json()["data"] == []
    lazy.is_resident = True
    cfg.embedding_engine.is_loaded = True
    body = client.get("/v1/models").json()
    assert [m["id"] for m in body["data"]] == ["voice", "embeddings"]
    assert body["data"][1]["capabilities"] == ["embedding"]
    assert "embeddings" not in {m["slug"] for m in body["models"]}


def test_discovery_preserves_configured_bearer_auth(discovery, monkeypatch):
    cfg, client = discovery
    cfg.api_key = "isolated-test-key"
    monkeypatch.delenv("YOUZI_ALLOW_ANONYMOUS_INFERENCE", raising=False)
    assert client.get("/v1/models").status_code == 401
    assert (
        client.get(
            "/v1/models", headers={"Authorization": "Bearer invalid"}
        ).status_code
        == 401
    )
    assert (
        client.get(
            "/v1/models", headers={"Authorization": "Bearer isolated-test-key"}
        ).status_code
        == 200
    )


def test_existing_agent_adapter_reads_context_and_reasoning_from_original_url(
    discovery, monkeypatch
):
    import vllm_mlx.server as server
    from vllm_mlx.agents import adapter
    from vllm_mlx.routes import models

    cfg, client = discovery
    cfg.engine, cfg.model_name, cfg.model_alias = object(), "local/chat-model", "chat"
    cfg.reasoning_parser_name = "qwen3"
    monkeypatch.setattr(models, "_resolve_context_window", lambda _: 32768)
    monkeypatch.setattr(server, "_reasoning_parser_name", None)
    paths = []

    def urlopen(url, **kwargs):
        path = urlsplit(url).path
        paths.append(path)
        response = client.get(path)
        assert response.status_code == 200
        return io.BytesIO(response.content)

    monkeypatch.setattr("urllib.request.urlopen", urlopen)
    assert adapter._detect_running_model("http://localhost/v1") == ("chat", 32768)
    assert (
        adapter.fetch_context_window("http://localhost/v1", "local/chat-model") == 32768
    )
    assert adapter.fetch_context_window("http://localhost/v1", "chat") == 32768
    assert adapter.fetch_reasoning_support("http://localhost/v1", "chat") is True
    cfg.reasoning_parser_name = None
    assert adapter.fetch_reasoning_support("http://localhost/v1", "chat") is False
    assert paths and set(paths) == {"/v1/models"}


def test_official_openai_sdk_accepts_extended_models(discovery):
    openai = pytest.importorskip(
        "openai", reason="Run with the isolated official SDK smoke environment"
    )
    import httpx

    cfg, client = discovery
    cfg.engine, cfg.model_name, cfg.model_alias = object(), "local/chat-model", "chat"

    def handle(request):
        result = client.get(request.url.path)
        return httpx.Response(result.status_code, json=result.json(), request=request)

    with httpx.Client(transport=httpx.MockTransport(handle)) as transport:
        sdk = openai.OpenAI(
            base_url="http://localhost/v1",
            api_key="test-only-key",
            http_client=transport,
            max_retries=0,
            _strict_response_validation=True,
        )
        result = sdk.models.list()
        assert result.object == "list"
        assert [model.id for model in result.data] == ["local/chat-model", "chat"]
        assert result.data[0].object == "model"
        assert result.data[0].owned_by == "youzi"
        retrieved = sdk.models.retrieve("local/chat-model")
        assert retrieved.model_dump() == result.data[0].model_dump()
        assert result.data[0].model_extra["capabilities"] == ["text"]
        assert [item["slug"] for item in result.model_extra["models"]] == [
            "local/chat-model",
            "chat",
        ]


def test_real_modality_profiles_keep_media_out_of_codex_chat_catalog(discovery):
    """Exercise actual profile resolution, not text-shaped modality placeholders."""
    from vllm_mlx.model_aliases import resolve_profile

    cfg, client = discovery
    cfg.model_registry = ModelRegistry()
    expected = {}
    for alias, capability in [
        ("qwen3.5-4b-4bit", "text"),
        ("z-image-turbo", "image.generation"),
        ("cogvideox-fun-5b-q4", "video.generation"),
        ("kokoro", "audio.speech"),
    ]:
        profile = resolve_profile(alias)
        canonical = profile.hf_path if profile else "mlx-community/Kokoro-82M-bf16"
        cfg.model_registry.add(
            ModelEntry(
                engine=SimpleNamespace(is_resident=True),
                model_name=canonical,
                model_path=canonical,
                aliases={alias},
            )
        )
        expected[canonical] = expected[alias] = capability

    # Listing must neither route traffic nor touch the residency access hook.
    def unexpected_access(_):
        pytest.fail("Model discovery must not access/load an engine")

    cfg.model_registry.on_engine_access = unexpected_access
    body = client.get("/v1/models").json()
    assert {card["id"] for card in body["data"]} == set(expected)
    for card in body["data"]:
        assert expected[card["id"]] in card["capabilities"]
    assert {card["slug"] for card in body["models"]} == {
        name for name, capability in expected.items() if capability == "text"
    }
