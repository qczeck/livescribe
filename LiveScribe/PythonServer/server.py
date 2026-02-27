#!/usr/bin/env python3
"""
server.py — LiveScribe WebSocket transcription server.

Protocol
--------
Swift → Server  binary frame : raw float32 audio (16 kHz mono, little-endian)
Swift → Server  text  frame  : JSON control message
    {"type": "start"}   — begin a new session (clears buffer)
    {"type": "stop"}    — end session (server drains remaining audio)

Server → Swift  text  frame  : JSON response
    {"type": "ready"}                              — model loaded, accepting audio
    {"type": "transcript", "text": "...", "is_final": false}
    {"type": "error",      "message": "..."}

Audio chunking
--------------
Swift sends audio in ~3-second binary frames (48 000 float32 samples at 16 kHz).
The server accumulates frames and transcribes each one independently, prepending
a small overlap from the previous chunk to avoid cutting words at boundaries.
"""

import asyncio
import json
import os
import signal
import sys
import threading
import time
import numpy as np
import websockets

# Suppress tqdm progress bars from mlx-whisper/huggingface_hub leaking into console
os.environ.setdefault("TQDM_DISABLE", "1")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")

from transcriber import Transcriber, SAMPLE_RATE


# ---------------------------------------------------------------------------
# Parent-death watchdog
# ---------------------------------------------------------------------------
# If the Swift app crashes or is force-killed, applicationWillTerminate never
# runs. This daemon thread polls the parent PID every 2 s and self-terminates
# when the parent is gone, so the server never becomes an orphan.

def _parent_watchdog() -> None:
    ppid = os.getppid()
    while True:
        time.sleep(2)
        try:
            os.kill(ppid, 0)  # signal 0 = existence check only
        except (ProcessLookupError, PermissionError):
            print("[server] Parent process gone — shutting down.", flush=True)
            os.kill(os.getpid(), signal.SIGTERM)
            return


threading.Thread(target=_parent_watchdog, daemon=True).start()


# Clean SIGTERM handler so the server exits with code 0 (not an unhandled signal)
def _handle_sigterm(signum, frame):
    print("[server] Received SIGTERM — shutting down.", flush=True)
    sys.exit(0)


signal.signal(signal.SIGTERM, _handle_sigterm)

HOST = "127.0.0.1"
PORT = int(os.environ.get("LIVESCRIBE_PORT", "8765"))
MODEL_SIZE = os.environ.get("LIVESCRIBE_MODEL", "small")

# Small overlap prepended to each chunk to avoid cutting words at boundaries.
# 0.15 s is enough to catch split words without causing noticeable repetition.
OVERLAP_SAMPLES = int(SAMPLE_RATE * 0.15)


# ---------------------------------------------------------------------------
# Session state
# ---------------------------------------------------------------------------

class Session:
    """Holds per-connection state."""

    def __init__(self):
        self.active = False
        self.overlap: np.ndarray = np.array([], dtype=np.float32)

    def reset(self):
        self.active = True
        self.overlap = np.array([], dtype=np.float32)

    def stop(self):
        self.active = False
        self.overlap = np.array([], dtype=np.float32)


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------

async def handler(websocket, transcriber: Transcriber):
    session = Session()
    remote = websocket.remote_address

    print(f"[server] Client connected: {remote}", flush=True)

    try:
        async for message in websocket:
            # ── Text control message ──────────────────────────────────────
            if isinstance(message, str):
                try:
                    cmd = json.loads(message)
                except json.JSONDecodeError:
                    await _send(websocket, {"type": "error", "message": "Invalid JSON"})
                    continue

                if cmd.get("type") == "start":
                    session.reset()
                    print("[server] Session started", flush=True)

                elif cmd.get("type") == "stop":
                    session.stop()
                    print("[server] Session stopped", flush=True)

            # ── Binary audio frame ────────────────────────────────────────
            elif isinstance(message, bytes):
                if not session.active:
                    continue  # ignore audio outside a session

                # Decode float32 little-endian samples
                n_samples = len(message) // 4
                if n_samples == 0:
                    continue

                chunk = np.frombuffer(message, dtype="<f4").astype(np.float32)

                # Prepend overlap from previous chunk
                audio = (
                    np.concatenate([session.overlap, chunk])
                    if len(session.overlap) > 0
                    else chunk
                )

                # Update overlap for next chunk
                session.overlap = chunk[-OVERLAP_SAMPLES:] if len(chunk) >= OVERLAP_SAMPLES else chunk

                # Transcribe (may be slow — run in executor to avoid blocking)
                loop = asyncio.get_event_loop()
                text = await loop.run_in_executor(None, transcriber.transcribe, audio)

                if text:
                    await _send(websocket, {
                        "type": "transcript",
                        "text": text,
                        "is_final": False,
                    })

    except websockets.exceptions.ConnectionClosedOK:
        pass
    except websockets.exceptions.ConnectionClosedError as e:
        print(f"[server] Connection closed with error: {e}", flush=True)
    finally:
        print(f"[server] Client disconnected: {remote}", flush=True)


async def _send(ws, payload: dict):
    try:
        await ws.send(json.dumps(payload))
    except websockets.exceptions.ConnectionClosed:
        pass


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def main():
    print(f"[server] Loading Whisper model '{MODEL_SIZE}' …", flush=True)
    transcriber = Transcriber(model_size=MODEL_SIZE)

    async def _handler(ws):
        await handler(ws, transcriber)

    # Retry binding — the previous server instance may still be releasing the port
    for attempt in range(1, 7):
        try:
            async with websockets.serve(_handler, HOST, PORT):
                print(f"[server] Listening on ws://{HOST}:{PORT}", flush=True)
                print("READY", flush=True)
                await asyncio.Future()  # run forever
                return
        except OSError as e:
            if e.errno == 48 and attempt < 6:  # EADDRINUSE
                print(f"[server] Port {PORT} busy, retrying in 2 s… ({attempt}/5)", flush=True)
                await asyncio.sleep(2)
            else:
                raise


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[server] Shutting down.", flush=True)
