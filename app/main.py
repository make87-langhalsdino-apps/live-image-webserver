#!/usr/bin/env python3
"""
Subscribes to a Zenoh JPEG topic and serves the newest frame on http://localhost:8080

Endpoints
---------
GET /image      → latest frame as image/jpeg   (404 until first image)
WS  /stream     → pushes each new JPEG binary
"""

from __future__ import annotations

import asyncio
import logging
import signal
from pathlib import Path
from typing import Optional

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import Response

import make87 as m87
from make87.interfaces.zenoh import ZenohInterface
from make87_messages.image.compressed.image_jpeg_pb2 import ImageJPEG

# ───────────────────────────────  config  ────────────────────────────────
TOPIC: str = "DETECTED_CHANGED_IMAGE" 
HTTP_PORT: int = 8080

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("image_server")

# ───────────────────────────  shared state  ──────────────────────────────
class LatestImage:
    """Thread-safe container that broadcasts on update."""

    def __init__(self) -> None:
        self._data: Optional[bytes] = None
        self._event = asyncio.Event()

    @property
    def available(self) -> bool:
        return self._data is not None

    def get(self) -> bytes:
        if self._data is None:
            raise RuntimeError("No image yet")
        return self._data

    def update(self, jpeg: bytes) -> None:
        self._data = jpeg
        # allow any awaiters of .wait() to resume
        self._event.set()
        self._event = asyncio.Event()  # create a new event for next frame


latest = LatestImage()

# ────────────────────────────  FastAPI app  ──────────────────────────────
app = FastAPI(title="Live Camera Image Server")


@app.get("/image", summary="Return the newest JPEG")
async def get_image() -> Response:
    if not latest.available:
        return Response(status_code=404, content="No image received yet")
    return Response(content=latest.get(), media_type="image/jpeg")


@app.websocket("/stream")
async def stream_images(ws: WebSocket):
    await ws.accept()
    log.info("WebSocket client connected")

    try:
        # Immediately send the current frame (if any) on connect
        if latest.available:
            await ws.send_bytes(latest.get())

        # Push every new frame as soon as it arrives
        while True:
            await latest._event.wait()
            await ws.send_bytes(latest.get())
    except WebSocketDisconnect:
        log.info("WebSocket client disconnected")
    except Exception as e:
        log.warning("WebSocket error: %s", e)


# ────────────────────────────  Zenoh task  ───────────────────────────────
async def zenoh_listener() -> None:
    """
    Block-waiting on Zenoh samples and push JPEGs into `latest`.
    Runs inside the main asyncio loop to avoid thread-sync headaches.
    """
    cfg = m87.config.load_config_from_env()
    zenoh = ZenohInterface("zenoh-client", make87_config=cfg)
    sub = zenoh.get_subscriber(TOPIC)
    decoder = m87.encodings.ProtobufEncoder(ImageJPEG)

    log.info("Subscribed to Zenoh topic %s", TOPIC)

    # recv() is blocking → run it in a separate thread to keep asyncio happy
    loop = asyncio.get_running_loop()
    while True:
        sample = await loop.run_in_executor(None, sub.recv)  # type: ignore[arg-type]
        if not sample.payload:
            continue

        jpeg_msg = decoder.decode(sample.payload.to_bytes())
        latest.update(jpeg_msg.data)
        log.debug("Received image (%d bytes)", len(jpeg_msg.data))


# ─────────────────────────────  startup  ─────────────────────────────────
def main() -> None:
    """
    Spins up both the Zenoh subscriber and the HTTP server under the same
    asyncio event loop for clean shutdown.
    """
    async def _async_main():
        # schedule Zenoh task
        task = asyncio.create_task(zenoh_listener(), name="zenoh-listener")

        # graceful shutdown on SIGTERM / Ctrl-C
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, task.cancel)

        # run the HTTP server (blocks until shutdown)
        config = uvicorn.Config(app, host="0.0.0.0", port=HTTP_PORT, log_level="info")
        server = uvicorn.Server(config)
        try:
            await server.serve()
        finally:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task

    import contextlib
    asyncio.run(_async_main())


if __name__ == "__main__":
    main()
