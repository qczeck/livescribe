#!/usr/bin/env python3
"""
test_client.py — End-to-end test for the LiveScribe WebSocket server.

Protocol:
  1. Connect to ws://127.0.0.1:8765
  2. Wait for {"type": "ready"} (server signals model is loaded)
  3. Send {"type": "start"}
  4. Send one binary frame: 3-second 440 Hz sine wave at 16 kHz mono float32
     (48 000 samples)
  5. Wait up to 30 seconds for {"type": "transcript"}
  6. Send {"type": "stop"}
  7. Print PASS (exit 0) if a transcript message arrived, FAIL (exit 1) otherwise

Note: The server only emits a transcript message when Whisper returns non-empty
text. A pure sine wave may or may not produce output depending on the model.
The test prints PASS on any transcript frame received and records its text.
"""

import asyncio
import json
import sys

import numpy as np
import websockets


URI = "ws://127.0.0.1:8765"
TIMEOUT = 30.0   # seconds to wait for a transcript reply


async def run_test() -> bool:
    """Returns True if a transcript message was received."""
    print(f"[client] Connecting to {URI} …")

    async with websockets.connect(URI) as ws:
        print("[client] Connected.")

        # ------------------------------------------------------------------
        # Wait for the server's "ready" signal (it may arrive immediately,
        # or we might have connected before/after — handle both cases).
        # We give it 5 s; if no "ready" arrives we proceed anyway (the server
        # already printed READY to stdout before we connected).
        # ------------------------------------------------------------------
        print("[client] Waiting for ready signal …")
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=5.0)
            msg = json.loads(raw)
            if msg.get("type") == "ready":
                print("[client] Server is ready.")
            else:
                print(f"[client] First message was not 'ready': {msg}")
        except asyncio.TimeoutError:
            print("[client] No 'ready' message received within 5 s — proceeding anyway.")

        # ------------------------------------------------------------------
        # Send start command
        # ------------------------------------------------------------------
        print("[client] Sending {\"type\": \"start\"} …")
        await ws.send(json.dumps({"type": "start"}))

        # ------------------------------------------------------------------
        # Build audio: 3-second 440 Hz sine wave, 16 kHz mono float32
        # 3 s * 16 000 samples/s = 48 000 samples
        # ------------------------------------------------------------------
        n_samples = 48_000
        t = np.arange(n_samples) / 16_000.0
        audio = np.sin(2 * np.pi * 440 * t).astype(np.float32)
        audio_bytes = audio.tobytes()
        print(f"[client] Sending binary audio frame: {len(audio_bytes)} bytes "
              f"({n_samples} float32 samples, 3 s @ 16 kHz) …")
        await ws.send(audio_bytes)

        # ------------------------------------------------------------------
        # Wait for a transcript response
        # ------------------------------------------------------------------
        print(f"[client] Waiting up to {TIMEOUT} s for transcript …")
        transcript_received = False
        transcript_text = None

        try:
            deadline = asyncio.get_event_loop().time() + TIMEOUT
            while asyncio.get_event_loop().time() < deadline:
                remaining = deadline - asyncio.get_event_loop().time()
                if remaining <= 0:
                    break
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
                except asyncio.TimeoutError:
                    break

                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    print(f"[client] Non-JSON message received: {raw!r}")
                    continue

                msg_type = msg.get("type")
                print(f"[client] Received: {msg}")

                if msg_type == "transcript":
                    transcript_received = True
                    transcript_text = msg.get("text", "")
                    break
                elif msg_type == "error":
                    print(f"[client] ERROR from server: {msg.get('message')}")
                    break
                # Ignore any other message types and keep waiting

        except websockets.exceptions.ConnectionClosed as e:
            print(f"[client] Connection closed unexpectedly: {e}")

        # ------------------------------------------------------------------
        # Send stop command
        # ------------------------------------------------------------------
        print("[client] Sending {\"type\": \"stop\"} …")
        try:
            await ws.send(json.dumps({"type": "stop"}))
        except websockets.exceptions.ConnectionClosed:
            pass

        return transcript_received, transcript_text


def main():
    try:
        received, text = asyncio.run(run_test())
    except Exception as e:
        print(f"[client] Fatal error: {e}")
        print("FAIL")
        sys.exit(1)

    if received:
        print(f"\nTranscript text: {text!r}")
        print("PASS")
        sys.exit(0)
    else:
        print("\nNo transcript message received within the timeout.")
        print("FAIL")
        sys.exit(1)


if __name__ == "__main__":
    main()
