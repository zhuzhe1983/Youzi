# SPDX-License-Identifier: Apache-2.0
"""Image model load/render/release must not follow asyncio's rotating workers."""
import asyncio
from concurrent.futures import ThreadPoolExecutor
from functools import partial
import threading
from types import SimpleNamespace

from PIL import Image
import pytest

from vllm_mlx.image.engine import ImageRuntimeError
from vllm_mlx.routes._async_utils import run_to_completion
from vllm_mlx.runtime.image_lane import ImageEngine


@pytest.fixture
def lane(monkeypatch):
    engine = ImageEngine("filipstrand/Z-Image-Turbo-mflux-4bit")
    events = []

    class ThreadBoundModel:
        def __init__(self):
            self.owner = threading.get_ident()
            events.append(("load", self.owner))

        def generate_image(self, **kwargs):
            assert threading.get_ident() == self.owner, "cross-thread MLX stream"
            events.append(("render", threading.get_ident()))
            return SimpleNamespace(image=Image.new("RGB", (8, 8), (200, 40, 40)))

        def __del__(self):
            events.append(("release", threading.get_ident()))

    monkeypatch.setattr(engine._engine, "_ensure_runtime_assets", lambda: None)
    monkeypatch.setattr(engine._engine, "_verify_weights_complete", lambda: None)
    monkeypatch.setattr(engine._engine, "_build_model", ThreadBoundModel)
    monkeypatch.setattr(engine._engine, "_build_edit_model", ThreadBoundModel)
    yield engine, events
    # Even a failed assertion cannot leak a live executor to the next test.
    asyncio.run(engine.stop())


def test_preload_repeated_parallel_callers_and_release_share_one_owner(lane):
    engine, events = lane
    barrier = threading.Barrier(3)
    callers = set()

    def render():
        callers.add(threading.get_ident())
        barrier.wait(timeout=5)
        return engine.generate(prompt="a red square")

    with ThreadPoolExecutor(max_workers=3) as clients:
        clients.submit(engine.ensure_resident).result(timeout=5)
        for _ in range(2):
            results = [clients.submit(render) for _ in range(3)]
            assert all(f.result(timeout=5).startswith(b"\x89PNG") for f in results)
    asyncio.run(engine.stop())
    assert len(callers) == 3
    assert [name for name, _ in events] == ["load"] + ["render"] * 6 + ["release"]
    owners = {thread for _, thread in events}
    assert len(owners) == 1 and owners.isdisjoint(callers)
    assert not engine.is_resident
    with pytest.raises(ImageRuntimeError, match="stopped"):
        engine.generate(prompt="no resurrection")


def test_mode_reload_stays_on_owner(lane):
    engine, events = lane
    # The real dual-mode adapter reuses this boundary for each variant.
    with ThreadPoolExecutor(max_workers=2) as callers:
        callers.submit(partial(engine.ensure_resident, mode="generation")).result(timeout=5)
        callers.submit(partial(engine.ensure_resident, mode="editing")).result(timeout=5)
    asyncio.run(engine.stop())
    assert [name for name, _ in events] == ["load", "release", "load", "release"]
    assert len({thread for _, thread in events}) == 1


async def test_canceled_route_drains_real_worker_and_remains_usable(lane, monkeypatch):
    engine, _ = lane
    began, finish = threading.Event(), threading.Event()
    original = engine._engine.generate

    def slow(**kwargs):
        began.set()
        assert finish.wait(5)
        return original(**kwargs)

    monkeypatch.setattr(engine._engine, "generate", slow)
    request = asyncio.create_task(run_to_completion(partial(engine.generate, prompt="a red square")))
    try:
        assert await asyncio.to_thread(began.wait, 5)
        request.cancel()
        await asyncio.sleep(0.03)
        request.cancel()
        await asyncio.sleep(0.03)
        assert not request.done()
    finally:
        finish.set()
    with pytest.raises(asyncio.CancelledError):
        await request
    assert (await asyncio.to_thread(engine.generate, prompt="next image")).startswith(b"\x89PNG")


async def test_canceled_stop_does_not_release_weights_during_render(lane, monkeypatch):
    engine, events = lane
    await asyncio.to_thread(engine.ensure_resident)
    began, finish = threading.Event(), threading.Event()
    original = engine._engine.generate

    def slow(**kwargs):
        began.set()
        assert finish.wait(5)
        return original(**kwargs)

    monkeypatch.setattr(engine._engine, "generate", slow)
    render = asyncio.create_task(asyncio.to_thread(engine.generate, prompt="a square"))
    assert await asyncio.to_thread(began.wait, 5)
    stop = asyncio.create_task(engine.stop())
    try:
        await asyncio.sleep(0.03)
        stop.cancel()
        await asyncio.sleep(0.03)
        stop.cancel()
        await asyncio.sleep(0.03)
        assert not stop.done() and engine.is_resident
        assert all(name != "release" for name, _ in events)
    finally:
        finish.set()
    await render
    with pytest.raises(asyncio.CancelledError):
        await stop
    assert events[-1][0] == "release"
    assert len({thread for _, thread in events}) == 1
    await engine.stop()  # idempotent


def test_idle_adapter_does_not_start_worker():
    engine = ImageEngine("filipstrand/Z-Image-Turbo-mflux-4bit")
    assert engine._worker is None
    asyncio.run(engine.stop())
    assert engine._worker is None
