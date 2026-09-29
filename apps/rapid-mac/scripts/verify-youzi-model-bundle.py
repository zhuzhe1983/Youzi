#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline protocol smoke against a complete, sourceless Youzi app runtime.

Use the app's own Python with -P -B, PYTHONNOUSERSITE=1 and PYTHONPATH pointing
only at its site-packages. See the conversation-video decision document for an
isolated invocation. Engines are synthetic; TestClient never connects to the
user's running service, and video files live in a temporary folder. This is not
model inference, full MP4 decoding or physical audio acceptance.
"""

import importlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
from unittest.mock import patch


def main():
    if not __debug__:
        raise SystemExit("Do not run this assertion-based smoke with -O")
    if len(sys.argv) != 2:
        raise SystemExit(
            "usage: paired-python -P -B verify-youzi-model-bundle.py SITE_PACKAGES"
        )
    root = Path(sys.argv[1]).resolve(strict=True)
    assert root.name == "site-packages", root
    assert Path(sys.executable).resolve().is_relative_to(root.parent / "python")
    assert sys.flags.safe_path, "Use -P to exclude the source checkout from sys.path"
    assert os.environ.get("RAPID_DESKTOP_NO_PORT_SWEEP") == "1"
    assert all(Path(p).resolve().is_relative_to(root.parent) for p in sys.path), sys.path
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"

    # Validate the interpreter and search paths before importing the application.
    from fastapi import FastAPI, HTTPException
    from fastapi.testclient import TestClient
    from vllm_mlx.config import get_config
    from vllm_mlx.runtime.model_loading_policy import resolve_request_model
    from vllm_mlx.runtime.model_registry import ModelEntry, ModelRegistry

    modules = [
        "vllm_mlx",
        "vllm_mlx.runtime.model_loading_policy",
        "vllm_mlx.routes.chat",
        "vllm_mlx.routes.completions",
        "vllm_mlx.routes.responses",
        "vllm_mlx.routes.anthropic",
        "vllm_mlx.routes.audio",
        "vllm_mlx.routes.images",
        "vllm_mlx.routes.video",
        "vllm_mlx.routes.residency",
    ]
    for name in modules:
        module = importlib.import_module(name)
        path = Path(module.__file__).resolve()
        assert path.is_relative_to(root), (name, path)
        if name != "vllm_mlx":
            assert path.suffix == ".pyc", (name, path)
    assert all(Path(p).resolve().is_relative_to(root.parent) for p in sys.path), sys.path

    cfg = get_config()
    cfg.api_key = "ephemeral-bundle-probe"
    cfg.automatic_model_pool = {"chat": ["not-loaded", "preferred"]}
    cfg.residency_manager = None
    registry = ModelRegistry()
    for name in ("primary", "preferred"):
        engine = SimpleNamespace(
            is_image_gen=False, is_video_gen=False, model_name=name
        )
        registry.add(ModelEntry(
            engine=engine, model_name=name, model_path=f"local/{name}", aliases=[name]
        ))
    cfg.model_registry = registry
    cfg.engine = registry.get_engine("primary")
    cfg.model_name = "primary"
    app = FastAPI()
    selected = []

    def capture(name=None):
        selected.append(name)
        raise HTTPException(418, "bundle probe engine boundary")

    for name in ("chat", "completions", "responses", "anthropic"):
        module = importlib.import_module("vllm_mlx.routes." + name)
        module.get_engine = capture
        app.include_router(module.router)
    app.include_router(importlib.import_module("vllm_mlx.routes.residency").router)
    video = importlib.import_module("vllm_mlx.routes.video")
    app.include_router(video.router)
    headers = {"Authorization": "Bearer ephemeral-bundle-probe"}
    requests = {
        "/v1/chat/completions": {"messages": [{"role": "user", "content": "hello"}]},
        "/v1/completions": {"prompt": "hello"},
        "/v1/responses": {"input": "hello"},
        "/v1/messages": {
            "messages": [{"role": "user", "content": "hello"}], "max_tokens": 4
        },
        "/v1/messages/count_tokens": {
            "messages": [{"role": "user", "content": "hello"}]
        },
    }
    with TestClient(app) as client:
        for path, payload in requests.items():
            r = client.post(path, json={**payload, "model": "default"}, headers=headers)
            assert r.status_code == 418, (path, r.status_code, r.text)
            assert selected[-1] == "preferred"
            r = client.post(path, json={**payload, "model": "primary"}, headers=headers)
            assert r.status_code == 418 and selected[-1] == "primary", (path, r.text)
            count = len(selected)
            r = client.post(path, json={**payload, "model": "typo"}, headers=headers)
            assert r.status_code == 409 and len(selected) == count, (path, r.text)

        r = client.put("/v1/service/model-policy", json={"automatic": {}})
        assert r.status_code == 401, r.text
        r = client.put(
            "/v1/service/model-policy",
            json={"automatic": {"chat": ["primary"]}}, headers=headers,
        )
        assert r.status_code == 200, r.text
        assert resolve_request_model("default", "chat") == "primary"
        assert registry.list_model_names() == ["primary", "preferred"]
        print(json.dumps({
            "imports": len(modules), "text_routes": len(requests),
            "exact_and_automatic": "passed", "authenticated_live_policy": "passed",
            "weights_loaded": False,
        }))

        video_engine = SimpleNamespace(
            is_image_gen=False, is_video_gen=True, model_name="video-explicit"
        )
        registry.add(ModelEntry(
            engine=video_engine, model_name="video-explicit",
            model_path="local/video-explicit", aliases=["video-explicit"],
        ))
        cfg.automatic_model_pool["video"] = []
        r = client.get(
            "/v1/videos/capabilities", params={"model": "video-explicit"},
            headers=headers,
        )
        assert r.status_code == 200 and r.json()["model"] == "video-explicit", r.text
        r = client.get("/v1/videos/capabilities", headers=headers)
        assert r.status_code == 409, r.text
        assert cfg.automatic_model_pool["video"] == []
        assert cfg.engine.model_name == "primary"
        print(json.dumps({
            "explicit_video_capabilities": "passed",
            "empty_video_pool": "rejected_without_load", "primary_chat": "preserved",
        }))

    # Exercise form/HTTP parsing and completed-job cancellation against the
    # bundled bytecode, but never construct an actual inference engine.
    class FakeEngine:
        is_image_gen = False
        is_video_gen = True
        model_name = "notapalindrome/ltx23-mlx-av-q4"

        def generate(self, *, output_path, **kwargs):
            output_path.write_bytes(bytes([0, 0, 0, 20]) + b"ftypisom0000")

    fake = FakeEngine()
    registry.add(ModelEntry(
        engine=fake, model_name=fake.model_name, model_path=fake.model_name,
        aliases=["ltx-2.3-mlx-q4"],
    ))
    video_app = FastAPI()
    video_app.include_router(video.router)
    with (
        tempfile.TemporaryDirectory(prefix="youzi-video-bundle-smoke-") as temp,
        patch.object(video, "_jobs_root", Path(temp)),
        patch.object(video, "_jobs_are_persistent", False),
        TestClient(video_app) as client,
    ):
        for requested in ("ltx-2.3-mlx-q4", fake.model_name):
            payload = {
                "prompt": "synthetic moon", "model": requested,
                "seconds": "1", "size": "512x512", "seed": "42",
            }
            r = client.post("/v1/videos", data=payload)
            assert r.status_code == 401, r.text
            r = client.post("/v1/videos", data=payload, headers=headers)
            assert r.status_code == 200, (r.status_code, r.text)
            job = r.json()
            assert job["model"] == requested, job
            path = "/v1/videos/" + job["id"]
            for _ in range(200):
                r = client.get(path, headers=headers)
                assert r.status_code == 200 and r.json()["model"] == requested, r.text
                if r.json()["status"] in ("completed", "failed"):
                    break
                time.sleep(0.01)
            assert r.json()["status"] == "completed", r.text
            r = client.delete(path + "?pending_only=true", headers=headers)
            assert r.status_code == 409, r.text
            r = client.get(path + "/content", headers=headers)
            assert r.status_code == 200, r.text
            assert r.headers["content-type"] == "video/mp4", r.headers
            assert r.content[4:8] == b"ftyp"
            r = client.delete(path, headers=headers)
            assert r.status_code == 200 and r.json()["deleted"], r.text
    assert cfg.engine.model_name == "primary"
    assert cfg.automatic_model_pool["video"] == []
    print(json.dumps({
        "video_post_get_content": "passed", "alias_and_hf_identity": "preserved",
        "completed_cancellation_race": "preserved", "primary_chat": "preserved",
        "weights_loaded": False,
    }))


if __name__ == "__main__":
    main()
