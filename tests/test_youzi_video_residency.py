"""Desktop video is a secondary service; it never becomes the chat primary."""
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from vllm_mlx.runtime.model_registry import ModelEntry, ModelRegistry
from vllm_mlx.runtime.resident_models import ResidentModelBusyError, ResidentModelManager
from vllm_mlx.routes import video


def engines():
    chat = SimpleNamespace(is_video_gen=False)
    movie = SimpleNamespace(is_video_gen=True, model_name="local/video")
    registry = ModelRegistry()
    registry.add(ModelEntry(engine=chat, model_name="chat", model_path="chat"), is_default=True)
    registry.add(ModelEntry(engine=movie, model_name="video", model_path="local/video", aliases={"movie"}))
    return chat, movie, registry


def test_video_routes_resolve_secondary_model_exactly(monkeypatch):
    import vllm_mlx.config as config
    chat, movie, registry = engines()
    cfg = SimpleNamespace(engine=chat, model_registry=registry)
    monkeypatch.setattr(config, "get_config", lambda: cfg)
    assert video._video_engine("movie") is movie
    assert video._video_engine("local/video") is movie
    assert video._video_engine() is movie
    for wrong in ("chat", "not-installed"):
        with pytest.raises(HTTPException) as exc:
            video._video_engine(wrong)
        assert exc.value.status_code == 409
    assert cfg.engine is chat


@pytest.mark.asyncio
async def test_video_lease_prevents_eviction_without_changing_chat(monkeypatch):
    import vllm_mlx.config as config
    chat, movie, registry = engines()

    async def load(*args, **kwargs):
        return registry.get_entry("video")

    manager = ResidentModelManager(registry=registry, loader=load, memory_limit_bytes=10**9)
    manager.register_primary(registry.get_entry("chat"), estimated_bytes=100)
    await manager.load("video", estimated_bytes=100)
    monkeypatch.setattr(config, "get_config", lambda: SimpleNamespace(residency_manager=manager))
    async with video._video_engine_lease(movie):
        assert next(m for m in manager.snapshot()["models"] if m["id"] == "video")["active_requests"] == 1
        with pytest.raises(ResidentModelBusyError):
            await manager.unload("video")
    assert next(m for m in manager.snapshot()["models"] if m["id"] == "video")["active_requests"] == 0


@pytest.mark.asyncio
async def test_dynamic_video_load_keeps_primary_and_checks_runtime(monkeypatch):
    from vllm_mlx import server
    from vllm_mlx.runtime import video_lane
    chat = object()
    monkeypatch.setattr(server, "_engine", chat)
    calls = []
    monkeypatch.setattr(video_lane, "require_video_runtime_or_exit", lambda model: calls.append(model))
    monkeypatch.setattr(video_lane, "VideoEngine", lambda model_name: SimpleNamespace(model_name=model_name))
    entry = await server._load_dynamic_resident_model("Anes1032/Wan2.2-I2V-A14B-mlx-q8", None)
    assert calls == ["Anes1032/Wan2.2-I2V-A14B-mlx-q8"]
    assert entry.engine.model_name == calls[0]
    assert server._engine is chat

    def missing(model):
        raise SystemExit(2)
    monkeypatch.setattr(video_lane, "require_video_runtime_or_exit", missing)
    with pytest.raises(video_lane.VideoRuntimeError, match="Update the Youzi"):
        await server._load_dynamic_resident_model("Anes1032/Wan2.2-I2V-A14B-mlx-q8", None)
    assert server._engine is chat
