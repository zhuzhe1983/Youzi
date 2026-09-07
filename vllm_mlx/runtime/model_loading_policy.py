"""Desktop-owned preferred pool. Routing never grants permission to load weights.

Standalone CLI servers without a supplied policy retain their existing defaults.
An explicitly empty desktop pool is NOT permission to use a legacy default.
"""

from __future__ import annotations

import json
import os
from typing import Literal

Scene = Literal["chat", "transcription", "speech", "image", "video"]
ENV_KEY = "YOUZI_AUTOMATIC_MODEL_POOL"
SCENES = {"chat", "transcription", "speech", "image", "video"}


def validate_pools(pools):
    if not isinstance(pools, dict) or not set(pools).issubset(SCENES):
        raise ValueError("Unknown scene")
    for aliases in pools.values():
        if not isinstance(aliases, list) or len(aliases) > 128:
            raise ValueError("Invalid preferred model list")
        if any(
            not isinstance(a, str) or not a or a != a.strip() or len(a) > 256
            or a == "default" or any(ord(c) < 32 for c in a)
            for a in aliases
        ):
            raise ValueError("Preferred models must have explicit, nonempty aliases")
        if len(set(aliases)) != len(aliases):
            raise ValueError("Duplicate preferred model")
    return pools


def initial_pool() -> dict[str, list[str]] | None:
    raw = os.environ.get(ENV_KEY)
    if raw is None:
        return None
    # Invalid owned configuration fails closed; never resurrect CLI defaults.
    try:
        value = json.loads(raw)
        if not isinstance(value, dict) or set(value) != {"automatic"}:
            return {}
        return validate_pools(value["automatic"])
    except (ValueError, TypeError):
        return {}


def policy_enabled() -> bool:
    from ..config import get_config

    return getattr(get_config(), "automatic_model_pool", None) is not None


def _same_model(a: str, b: str) -> bool:
    if a == b:
        return True
    from ..audio.registry import resolve_audio_alias

    aa, ab = resolve_audio_alias(a), resolve_audio_alias(b)
    if aa is not None or ab is not None:
        return (aa.hf_id if aa else a) == (ab.hf_id if ab else b)
    from ..model_aliases import resolve_profile

    pa, pb = resolve_profile(a), resolve_profile(b)
    return (pa.hf_path if pa else a) == (pb.hf_path if pb else b)


def is_ready(alias: str, scene: Scene) -> bool:
    from ..config import get_config

    cfg = get_config()
    if scene in ("transcription", "speech"):
        from .audio_worker import audio_worker

        lane = "stt" if scene == "transcription" else "tts"
        return any(
            item["lane"] == lane and item["state"] in ("resident", "busy")
            and isinstance(item["model"], str) and _same_model(alias, item["model"])
            for item in audio_worker.snapshot()
        )
    registry = getattr(cfg, "model_registry", None)
    if registry is not None:
        # get_entry intentionally has a legacy default fallback. Membership
        # must be checked first, or a cold/typo alias looks deceptively ready.
        if alias not in registry:
            return False
        try:
            entry = registry.get_entry(alias)
        except KeyError:
            return False
        engine = entry.engine
    else:
        names = [getattr(cfg, key, None) for key in ("model_name", "model_alias", "model_path")]
        if not any(isinstance(name, str) and _same_model(alias, name) for name in names):
            return False
        engine = getattr(cfg, "engine", None)
    if engine is None:
        return False
    image = getattr(engine, "is_image_gen", False) is True
    video = getattr(engine, "is_video_gen", False) is True
    if scene == "image":
        return image
    if scene == "video":
        return video
    from ..audio.registry import is_audio_name

    return not image and not video and not is_audio_name(alias) and not any(
        getattr(engine, flag, False) is True for flag in ("is_audio", "is_embedding", "is_reranker")
    )


def resolve_request_model(
    requested: str | None, scene: Scene, *, require_explicit_ready: bool = True,
) -> str | None:
    """Reuse ready pool members in saved order; explicit requests never substitute.

    APIs have no interactive approval surface. Callers must explicitly use the
    authenticated load endpoint for cold models. Native tools ask for approval
    before calling that endpoint. Neither path modifies the preferred pool.
    """
    from ..config import get_config

    pool = getattr(get_config(), "automatic_model_pool", None)
    if pool is None:
        return requested
    automatic = not requested or requested == "default"
    if not automatic and not require_explicit_ready:
        return requested
    candidates = pool.get(scene, []) if automatic else [requested]
    for alias in candidates:
        if is_ready(alias, scene):
            return alias
    from fastapi import HTTPException

    message = (
        "No preferred model is ready for this scene. "
        "Configure/load a downloaded model in Youzi Model Settings."
        if automatic else
        "The requested model is not ready for this scene. Load that exact model "
        "in Youzi Model Settings or the authenticated model-load API."
    )
    raise HTTPException(status_code=409, detail={"error": {
        "message": message,
        "type": "invalid_request_error",
        "code": "automatic_model_not_ready" if automatic else "model_not_ready",
        "param": "model",
    }})


def reported_model_name(requested: str, configured: str | None) -> str:
    """Responses/SSE must report the chosen pool member, not the boot primary."""
    return requested if policy_enabled() else configured or requested
