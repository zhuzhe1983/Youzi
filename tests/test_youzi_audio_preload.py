"""Explicit audio residency must reuse inference caches and preserve other lanes."""

from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from vllm_mlx.config import get_config
from vllm_mlx.routes import audio, models, residency
from vllm_mlx.runtime import audio_worker as worker_module


@pytest.fixture
def lanes(monkeypatch):
    rows = {}
    for name in ("_tts_engine", "_stt_engine", "_aligner_engine"):
        monkeypatch.setattr(audio, name, None)
    monkeypatch.setattr(audio, "_check_audio_preload_capacity", lambda _: None)

    def run(lane, model, op, func, *args, **kwargs):
        result = func(*args, **kwargs)
        rows[lane] = dict(
            lane=lane,
            model=model if op != "unload" else None,
            state="resident" if op != "unload" else "registered",
            loaded_at=1 if op != "unload" else None,
        )
        return result

    monkeypatch.setattr(worker_module, "run_audio_mlx_sync", run)
    monkeypatch.setattr(
        worker_module.audio_worker, "snapshot", lambda: list(rows.values())
    )
    from vllm_mlx.audio.stt import STTEngine
    from vllm_mlx.audio.tts import TTSEngine

    monkeypatch.setattr(TTSEngine, "load", Mock())
    monkeypatch.setattr(STTEngine, "load", Mock())
    monkeypatch.setattr(TTSEngine, "unload", Mock())
    monkeypatch.setattr(STTEngine, "unload", Mock())
    return rows, TTSEngine, STTEngine


@pytest.mark.asyncio
async def test_preload_both_audio_lanes_preserves_chat_image_and_reuses_weights(
    lanes, monkeypatch
):
    rows, tts, stt = lanes
    cfg = get_config()
    chat, image = object(), object()
    monkeypatch.setattr(cfg, "engine", chat)
    monkeypatch.setattr(cfg, "model_registry", SimpleNamespace(image=image))
    result = await audio.preload_audio_model("kokoro")
    assert result["state"] == "resident"
    loaded = audio._tts_engine
    await audio.preload_audio_model("kokoro")
    assert audio._tts_engine is loaded
    tts.load.assert_called_once()
    # Speech uses this exact helper/cache, not another residency-only engine.
    assert audio._ensure_tts_loaded_blocking(loaded.model_name) is loaded
    tts.load.assert_called_once()
    await audio.preload_audio_model("whisper-small")
    assert rows["tts"]["state"] == rows["stt"]["state"] == "resident"
    assert cfg.engine is chat and cfg.model_registry.image is image
    tts.unload.assert_not_called()


@pytest.mark.asyncio
async def test_preflight_rejection_preserves_loaded_audio(lanes, monkeypatch):
    await audio.preload_audio_model("kokoro")
    old = audio._tts_engine

    def reject(_):
        raise HTTPException(status_code=507, detail="insufficient memory")

    monkeypatch.setattr(audio, "_check_audio_preload_capacity", reject)
    with pytest.raises(HTTPException) as exc:
        await audio.preload_audio_model("whisper-small")
    assert exc.value.status_code == 507
    assert audio._tts_engine is old


def test_preload_control_plane_requires_key_in_anonymous_mode(lanes, monkeypatch):
    monkeypatch.setattr(get_config(), "api_key", "preload-test-key")
    app = FastAPI()
    app.state.youzi_anonymous_inference = True
    app.include_router(residency.router)
    client = TestClient(app, base_url="http://127.0.0.1")
    assert (
        client.post("/v1/audio/models/load", json={"model": "kokoro"}).status_code
        == 401
    )
    response = client.post(
        "/v1/audio/models/load",
        json={"model": "kokoro"},
        headers={"Authorization": "Bearer preload-test-key"},
    )
    assert response.status_code == 200, response.text
    assert response.json()["state"] == "resident"


def test_discovery_includes_only_materialized_audio_lanes(lanes, monkeypatch):
    rows, _, _ = lanes
    cfg = get_config()
    for name, value in dict(
        ready=True,
        draining=False,
        engine=None,
        model_registry=None,
        embedding_engine=None,
        residency_manager=None,
    ).items():
        monkeypatch.setattr(cfg, name, value)
    rows["tts"] = dict(
        lane="tts", model="mlx-community/Kokoro-82M-bf16", state="resident", loaded_at=1
    )
    assert set(models._loaded_model_ids()) == {
        "kokoro",
        "mlx-community/Kokoro-82M-bf16",
    }
    rows["tts"]["state"] = "busy"
    assert len(models._loaded_model_ids()) == 2
    for state in ("loading", "failed", "registered"):
        rows["tts"]["state"] = state
        assert models._loaded_model_ids() == []


@pytest.mark.parametrize("extension", [".safetensors", ".npz"])
def test_preflight_accepts_cached_audio_weight_formats(
    tmp_path, monkeypatch, extension
):
    import huggingface_hub
    import psutil

    (tmp_path / ("weights" + extension)).write_bytes(b"cached weights")
    download = Mock(return_value=str(tmp_path))
    monkeypatch.setattr(huggingface_hub, "snapshot_download", download)
    monkeypatch.setattr(
        psutil, "virtual_memory", lambda: SimpleNamespace(available=2**30)
    )
    monkeypatch.setattr(get_config(), "residency_manager", None)
    audio._check_audio_preload_capacity("local/audio")
    download.assert_called_once_with("local/audio", local_files_only=True)


def test_preflight_rejects_incomplete_cache_and_capacity(tmp_path, monkeypatch):
    import huggingface_hub
    import psutil

    monkeypatch.setattr(
        huggingface_hub, "snapshot_download", lambda *a, **kw: str(tmp_path)
    )
    monkeypatch.setattr(
        psutil, "virtual_memory", lambda: SimpleNamespace(available=2**30)
    )
    monkeypatch.setattr(get_config(), "residency_manager", None)
    with pytest.raises(HTTPException) as exc:
        audio._check_audio_preload_capacity("local/audio")
    assert exc.value.status_code == 409
    (tmp_path / "weights.npz").write_bytes(b"cached weights")
    monkeypatch.setattr(
        get_config(),
        "residency_manager",
        SimpleNamespace(snapshot=lambda: {"memory_available_bytes": 1}),
    )
    with pytest.raises(HTTPException) as exc:
        audio._check_audio_preload_capacity("local/audio")
    assert exc.value.status_code == 507


@pytest.mark.asyncio
async def test_preload_rejects_whisper_weights_without_processor(lanes, monkeypatch):
    _, _, stt = lanes

    def load(self):
        self.model = SimpleNamespace(_processor=None)

    monkeypatch.setattr(stt, "load", load)
    with pytest.raises(HTTPException) as exc:
        await audio.preload_audio_model("whisper-small")
    assert exc.value.status_code == 409
    assert "processor" in exc.value.detail
    assert audio._stt_engine is None
