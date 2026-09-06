"""Desktop opt-in allows loopback inference, never management or browser access."""

import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient
from starlette.requests import Request

from vllm_mlx.config import get_config
from vllm_mlx.middleware.auth import allows_anonymous_inference, verify_api_key


@pytest.fixture(autouse=True)
def configured(monkeypatch):
    monkeypatch.setenv("YOUZI_ALLOW_ANONYMOUS_INFERENCE", "1")
    monkeypatch.setattr(get_config(), "api_key", "test-only-key")


def request(
    path="/v1/models", method="GET", peer="127.0.0.1", host="localhost", extra=()
):
    return Request(
        dict(
            type="http",
            method=method,
            path=path,
            raw_path=path.encode(),
            query_string=b"",
            scheme="http",
            server=("localhost", 8000),
            client=(peer, 32100),
            headers=[(b"host", host.encode()), *extra],
        )
    )


@pytest.mark.parametrize(
    "path,method",
    [
        ("/v1/models", "GET"),
        ("/v1/chat/completions", "POST"),
        ("/v1/images/generations", "POST"),
        ("/v1/images/edits", "POST"),
        ("/v1/audio/speech", "POST"),
        ("/v1/videos", "POST"),
        ("/v1/videos/job-1/content", "GET"),
    ],
)
def test_allowed(path, method):
    assert allows_anonymous_inference(request(path, method))


@pytest.mark.parametrize(
    "path,method",
    [
        ("/v1/models/residency", "GET"),
        ("/v1/models/load", "POST"),
        ("/v1/models/unload", "POST"),
        ("/v1/mcp/reload", "POST"),
        ("/v1/cache", "DELETE"),
        ("/v1/videos/job-1", "DELETE"),
        ("/admin", "GET"),
        ("/v1/models/foo", "GET"),
    ],
)
def test_admin_not_allowed(path, method):
    assert not allows_anonymous_inference(request(path, method))


@pytest.mark.parametrize(
    "kwargs",
    [
        dict(peer="192.168.1.2"),
        dict(host="attacker.example"),
        dict(extra=[(b"origin", b"null")]),
        dict(extra=[(b"origin", b"http://localhost")]),
        dict(extra=[(b"authorization", b"")]),
        dict(extra=[(b"x-api-key", b"wrong")]),
        dict(peer="192.168.1.2", extra=[(b"x-forwarded-for", b"127.0.0.1")]),
    ],
)
def test_fail_closed(kwargs):
    assert not allows_anonymous_inference(request(**kwargs))


def test_default_requires_key(monkeypatch):
    monkeypatch.delenv("YOUZI_ALLOW_ANONYMOUS_INFERENCE")
    assert not allows_anonymous_inference(request())


def test_dependency_authentication():
    app = FastAPI()

    @app.get("/v1/models", dependencies=[Depends(verify_api_key)])
    @app.get("/v1/models/residency", dependencies=[Depends(verify_api_key)])
    def endpoint():
        return {"ok": True}

    client = TestClient(app, base_url="http://localhost", client=("127.0.0.1", 1234))
    assert client.get("/v1/models").status_code == 200
    assert (
        client.get("/v1/models", headers={"Authorization": "Bearer wrong"}).status_code
        == 401
    )
    assert client.get("/v1/models/residency").status_code == 401
    assert (
        client.get(
            "/v1/models/residency", headers={"Authorization": "Bearer test-only-key"}
        ).status_code
        == 200
    )


def test_image_router_protected():
    from vllm_mlx.routes.images import router

    app = FastAPI()
    app.include_router(router)
    client = TestClient(app)
    assert (
        client.post("/v1/images/generations", json={"prompt": "test"}).status_code
        == 401
    )


@pytest.mark.parametrize("lane", ["video", "images"])
def test_media_preparse_auth_uses_same_policy(lane, monkeypatch):
    if lane == "video":
        from vllm_mlx.routes.video import VideoBodyLimitMiddleware as Middleware

        path = "/v1/videos"
    else:
        from vllm_mlx.routes.images import ImageBodyLimitMiddleware as Middleware

        path = "/v1/images/edits"
    app = FastAPI()
    app.add_middleware(Middleware)

    @app.post(path, dependencies=[Depends(verify_api_key)])
    def endpoint():
        return {"ok": True}

    client = TestClient(app, base_url="http://localhost", client=("127.0.0.1", 1234))
    assert client.post(path).status_code == 200
    assert (
        client.post(path, headers={"Authorization": "Bearer wrong"}).status_code == 401
    )
    assert (
        client.post(path, headers={"Origin": "https://example.com"}).status_code == 401
    )
    monkeypatch.delenv("YOUZI_ALLOW_ANONYMOUS_INFERENCE")
    assert client.post(path).status_code == 401
    assert (
        client.post(path, headers={"Authorization": "Bearer test-only-key"}).status_code
        == 200
    )


def test_auth_save_live_without_model_restart(monkeypatch):
    from vllm_mlx.routes.residency import router

    app = FastAPI()
    app.include_router(router)

    @app.get("/v1/models", dependencies=[Depends(verify_api_key)])
    def models():
        return {"object": "list", "data": []}

    client = TestClient(app, base_url="http://localhost", client=("127.0.0.1", 1234))
    headers = {"Authorization": "Bearer test-only-key"}
    monkeypatch.delenv("YOUZI_ALLOW_ANONYMOUS_INFERENCE", raising=False)
    assert client.get("/v1/models").status_code == 401
    for value in [True, False, True]:
        assert (
            client.put(
                "/v1/service/auth", json={"anonymous_inference": value}
            ).status_code
            == 401
        )
        result = client.put(
            "/v1/service/auth", json={"anonymous_inference": value}, headers=headers
        )
        assert result.status_code == 200
        assert result.json() == {"anonymous_inference": value}
        assert client.get("/v1/service/auth", headers=headers).json() == result.json()
        assert client.get("/v1/service/auth").status_code == 401
        assert client.get("/v1/models").status_code == (200 if value else 401)
        assert (
            client.get(
                "/v1/models", headers={"Authorization": "Bearer wrong"}
            ).status_code
            == 401
        )
    # A second app must not inherit the first app's runtime override.
    other = FastAPI()
    other.include_router(router)
    assert TestClient(other).get("/v1/service/auth", headers=headers).json() == {
        "anonymous_inference": False
    }
    for invalid in ["true", 1, None]:
        assert client.put(
            "/v1/service/auth", json={"anonymous_inference": invalid}, headers=headers
        ).status_code in (400, 422)
    assert client.put(
        "/v1/service/auth",
        json={"anonymous_inference": False, "api_key": "ignored"},
        headers=headers,
    ).status_code in (400, 422)
    assert client.get("/v1/service/auth", headers=headers).json() == {
        "anonymous_inference": True
    }


@pytest.mark.parametrize("lane", ["video", "images"])
def test_media_preparse_honors_live_auth_save(lane, monkeypatch):
    from vllm_mlx.routes.residency import router

    if lane == "video":
        from vllm_mlx.routes.video import VideoBodyLimitMiddleware as Middleware

        path = "/v1/videos"
    else:
        from vllm_mlx.routes.images import ImageBodyLimitMiddleware as Middleware

        path = "/v1/images/edits"
    monkeypatch.delenv("YOUZI_ALLOW_ANONYMOUS_INFERENCE", raising=False)
    app = FastAPI()
    app.add_middleware(Middleware)
    app.include_router(router)

    @app.post(path, dependencies=[Depends(verify_api_key)])
    def inference():
        return {"ok": True}

    client = TestClient(app, base_url="http://localhost", client=("127.0.0.1", 1234))
    for value in [False, True, False]:
        assert (
            client.put(
                "/v1/service/auth",
                json={"anonymous_inference": value},
                headers={"Authorization": "Bearer test-only-key"},
            ).status_code
            == 200
        )
        assert client.post(path).status_code == (200 if value else 401)
        assert (
            client.post(path, headers={"Origin": "https://example.com"}).status_code
            == 401
        )
