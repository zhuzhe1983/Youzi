"""Startup lists opt into co-loading without replacing or evicting siblings."""

import pytest
from pydantic import ValidationError

from vllm_mlx.routes.residency import AudioModelLoadRequest, ModelLoadRequest
from vllm_mlx.runtime.model_registry import ModelEntry, ModelRegistry
from vllm_mlx.runtime.resident_models import (
    ResidentModelCapacityError,
    ResidentModelError,
    ResidentModelManager,
)


class Engine:
    def __init__(self, kind):
        self.is_image_gen = kind == "image"
        self.is_video_gen = kind == "video"
        self.is_mllm = False
        self.stopped = False

    def get_stats(self):
        return {"num_running": 0, "num_waiting": 0}

    async def stop(self):
        self.stopped = True


def manager_fixture(limit=10, memory_reader=lambda: 0):
    registry = ModelRegistry()
    engines = {}

    async def loader(name, path, performance=None):
        engines[name] = Engine(name.split("-")[0])
        return ModelEntry(
            engine=engines[name], model_name=name, model_path=path or name
        )

    manager = ResidentModelManager(
        registry, loader, memory_limit_bytes=limit, memory_reader=memory_reader
    )
    return manager, registry, engines


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", ["chat", "image", "video"])
async def test_same_kind_models_can_coload_without_replacing(kind):
    manager, registry, engines = manager_fixture()
    for suffix in ("a", "b"):
        await manager.load(
            f"{kind}-{suffix}", estimated_bytes=2, pin=True, preserve_loaded=True
        )
    # Re-selecting an existing image/video model must not retire its sibling.
    await manager.load(f"{kind}-a", preserve_loaded=True)
    assert set(engines) == {f"{kind}-a", f"{kind}-b"}
    assert all(not engine.stopped for engine in engines.values())
    assert len(manager.snapshot()["models"]) == 2
    assert manager.evictions_total == 0
    assert registry.get_engine(f"{kind}-a") is engines[f"{kind}-a"]
    assert registry.get_engine(f"{kind}-b") is engines[f"{kind}-b"]


@pytest.mark.asyncio
async def test_preserved_admission_does_not_evict_even_unpinned_idle_models():
    manager, registry, engines = manager_fixture(limit=3)
    await manager.load("image-old", estimated_bytes=2)
    with pytest.raises(ResidentModelCapacityError, match="preserved"):
        await manager.load("image-new", estimated_bytes=2, preserve_loaded=True)
    assert "image-new" not in engines
    assert not engines["image-old"].stopped
    assert registry.get_engine("image-old") is engines["image-old"]
    assert manager.evictions_total == 0


@pytest.mark.asyncio
async def test_post_load_overrun_rolls_back_only_incoming_model():
    usage = [0]
    manager, registry, engines = manager_fixture(
        limit=10, memory_reader=lambda: usage[0]
    )
    await manager.load("chat-old", estimated_bytes=2)
    loader = manager.loader

    async def overrun(*args):
        result = await loader(*args)
        usage[0] = 20
        return result

    manager.loader = overrun
    with pytest.raises(ResidentModelCapacityError):
        await manager.load("video-new", estimated_bytes=2, preserve_loaded=True)
    assert engines["video-new"].stopped
    assert not engines["chat-old"].stopped
    assert "video-new" not in registry
    assert "chat-old" in registry


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "extra", [{"replace_group": "assistant"}, {"reload_if_changed": True}]
)
async def test_preserve_cannot_be_combined_with_destructive_actions(extra):
    manager, _, engines = manager_fixture()
    with pytest.raises(ResidentModelError, match="cannot replace or reload"):
        await manager.load("chat", preserve_loaded=True, **extra)
    assert not engines


@pytest.mark.parametrize("request_type", [ModelLoadRequest, AudioModelLoadRequest])
def test_preservation_flag_requires_a_real_boolean_and_is_opt_in(request_type):
    assert request_type(model="local").preserve_loaded is False
    assert request_type(model="local", preserve_loaded=True).preserve_loaded is True
    for invalid in ("true", 1, None):
        with pytest.raises(ValidationError):
            request_type(model="local", preserve_loaded=invalid)
