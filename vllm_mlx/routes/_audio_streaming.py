"""Lifecycle-safe incremental PCM response, independent of model backends."""

from __future__ import annotations

import asyncio
import logging

from starlette.responses import StreamingResponse

logger = logging.getLogger(__name__)


async def close_stream(source) -> None:
    """Drain close even across repeated cancellation before releasing leases."""
    task = asyncio.create_task(source.aclose())
    try:
        while not task.done():
            try:
                await asyncio.shield(task)
            except asyncio.CancelledError:
                continue
        task.result()
    except Exception:
        logger.exception("Speech stream cleanup failed")
        raise


class PCMStreamingResponse(StreamingResponse):
    """Close a pre-opened source even if send/receive fails before iteration.

    The route fetches one chunk before committing HTTP200 so startup errors
    remain JSON errors. Starlette alone does not close a suspended generator
    when cancellation happens in send(), rather than in iterator.__anext__().
    """

    def __init__(self, source, first: bytes):
        self.source = source

        async def body():
            yield first
            async for chunk in source:
                yield chunk

        super().__init__(
            body(),
            media_type="application/octet-stream",
            headers={
                "Cache-Control": "no-store",
                "X-Accel-Buffering": "no",
                "X-Audio-Sample-Rate": "24000",
                "X-Audio-Channels": "1",
                "X-Audio-Format": "pcm_s16le",
            },
        )

    async def __call__(self, scope, receive, send):
        try:
            await super().__call__(scope, receive, send)
        finally:
            await close_stream(self.source)
