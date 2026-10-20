"""Image residency rejects unsupported modes before admission or model assets."""

import asyncio
from unittest.mock import AsyncMock, Mock

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from vllm_mlx.image.engine import ImageRequestError, ImageRuntimeError
from vllm_mlx.middleware.auth import verify_api_key
from vllm_mlx.middleware.exception_handlers import install_exception_handlers
from vllm_mlx.routes import residency
from vllm_mlx.runtime.image_lane import ImageEngine


@pytest.fixture
def control_plane(monkeypatch):
    manager = Mock()
    manager.load = AsyncMock()
    monkeypatch.setattr(residency, "_manager", lambda: manager)
    app = FastAPI()
    install_exception_handlers(app)
    app.dependency_overrides[verify_api_key] = lambda: None
    app.include_router(residency.router)
    with TestClient(app) as client:
        yield client, manager


INVALID_MODES = [
    ("qwen-image", None, "editing", "qwen-image does not support image editing."),
    ("qwen-image", "Qwen/Qwen-Image-Edit-2509", "generation", "qwen-image-edit does not support image generation."),
]


@pytest.mark.parametrize("model,model_path,mode,message", INVALID_MODES)
def test_unsupported_mode_fails_before_manager_admission(control_plane, model, model_path, mode, message):
    client, manager = control_plane
    response = client.post("/v1/models/load", json={"model": model, "model_path": model_path, "image_mode": mode})
    assert response.status_code == 400
    assert response.json()["error"]["message"] == message
    manager.load.assert_not_awaited()


@pytest.mark.parametrize("model,model_path,mode,message", INVALID_MODES)
def test_dynamic_loader_rejects_before_assets(monkeypatch, model, model_path, mode, message):
    from vllm_mlx import server
    from vllm_mlx.image.engine import ImageGenerationEngine

    assets = Mock(side_effect=AssertionError("invalid mode touched model assets"))
    monkeypatch.setattr(ImageGenerationEngine, "_ensure_runtime_assets", assets)
    monkeypatch.setattr(ImageGenerationEngine, "_verify_weights_complete", assets)
    with pytest.raises(ImageRequestError, match=message):
        asyncio.run(server._load_dynamic_resident_model(model, model_path, image_mode=mode))
    assets.assert_not_called()


@pytest.mark.parametrize("model,model_path,mode,message", INVALID_MODES)
def test_resident_reuse_validates_mode_before_replacement(model, model_path, mode, message):
    from vllm_mlx.runtime.model_registry import ModelEntry, ModelRegistry
    from vllm_mlx.runtime.resident_models import ResidentModelManager

    engine = ImageEngine(model_path or model)
    registry = ModelRegistry()
    entry = ModelEntry(engine=engine, model_name=model, model_path=model)
    registry.add(entry, is_default=True)
    manager = ResidentModelManager(registry, AsyncMock(), memory_reader=lambda: 0, clock=lambda: 1.0)
    manager.register_primary(entry, estimated_bytes=1)
    original = manager.snapshot()
    with pytest.raises(ImageRequestError, match=message):
        asyncio.run(manager.load(model, image_mode=mode, replace_group="image-gen"))
    manager.loader.assert_not_awaited()
    assert manager.snapshot() == original
    assert engine._worker is None


def test_supported_mode_preserves_dynamic_load_worker_boundary(monkeypatch):
    from vllm_mlx import server

    modes = []
    monkeypatch.setattr(
        ImageEngine, "ensure_resident", lambda _self, *, mode=None: modes.append(mode)
    )
    entry = asyncio.run(
        server._load_dynamic_resident_model("qwen-image", None, image_mode="generation")
    )
    assert isinstance(entry.engine, ImageEngine)
    assert modes == ["generation"]
    assert entry.engine._worker is None


@pytest.mark.parametrize("wrapped", [False, True])
def test_request_errors_preserve_actionable_message(control_plane, wrapped):
    client, manager = control_plane
    error = ImageRequestError("unsupported image mode")
    if wrapped:
        wrapper = RuntimeError("private loader details")
        wrapper.__cause__ = error
        error = wrapper
    manager.load.side_effect = error
    response = client.post("/v1/models/load", json={"model": "unknown/model"})
    assert response.status_code == 400
    assert response.json()["error"]["message"] == "unsupported image mode"
    assert "private" not in response.text


def test_operational_error_remains_sanitized_server_failure(control_plane):
    client, manager = control_plane
    manager.load.side_effect = ImageRuntimeError("private checkpoint location")
    response = client.post("/v1/models/load", json={"model": "unknown/model"})
    assert response.status_code == 500
    assert response.json()["error"]["message"] == "Failed to load resident model: ImageRuntimeError"
    assert "private" not in response.text


def test_cause_cycle_stops_without_exposing_unrelated_context():
    error = RuntimeError("private details")
    error.__cause__ = error
    error.__context__ = ImageRequestError("unrelated context")
    assert residency._image_request_failure(error) is None
