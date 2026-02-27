# LiveScribe — macOS Menu Bar Audio Transcriber

## Project Overview

LiveScribe is a macOS menu bar app that captures system audio playing on the Mac and transcribes it live. Clicking the menu bar icon starts listening; clicking again stops and saves the transcript to a `.txt` file. The popover shows the rolling transcript in real time.

The old `reel_transcriber.py` CLI (Instagram reel download + transcribe) lives alongside this app and is kept as-is.

---

## Current Status

**All code written, compiles, integration tested. Not yet run live.**

- ✅ Python server + transcriber written and tested
- ✅ WebSocket protocol verified end-to-end (`test_client.py` → server → transcript returned)
- ✅ Swift app written (all 6 source files)
- ✅ Xcode project builds clean (`BUILD SUCCEEDED`, zero errors/warnings)
- ✅ Dev env vars baked into Xcode scheme via `project.yml`
- ⬜ First live run — open in Xcode, grant Screen Recording permission, test with real audio

---

## Architecture

Two-process model: Swift app + Python subprocess.

```
┌──────────────────────────────────────┐
│         Swift App (LiveScribe)       │
│                                      │
│  NSStatusItem (menu bar icon)        │
│       │                              │
│  NSPopover ──► SwiftUI PopoverView   │
│       │        (live transcript)     │
│       │                              │
│  AudioCaptureManager                 │
│  (ScreenCaptureKit → AVAudioConverter│
│   48kHz stereo → 16kHz mono float32) │
│       │                              │
│  TranscriptionClient                 │
│  (URLSessionWebSocketTask)           │
└──────────────┬───────────────────────┘
               │ WebSocket ws://127.0.0.1:8765
               │ Binary frames: float32 audio chunks
               │ Text frames: JSON control + transcript
┌──────────────▼───────────────────────┐
│       Python Server (server.py)      │
│                                      │
│  asyncio + websockets                │
│       │                              │
│  transcriber.py                      │
│  mlx-whisper (Apple Silicon primary) │
│  faster-whisper (CPU fallback)       │
└──────────────────────────────────────┘
```

**Swift is responsible for:** Menu bar UI, popover/SwiftUI view, ScreenCaptureKit audio capture, AVAudioConverter resampling, WebSocket client, file saving trigger.

**Python is responsible for:** WebSocket server, Whisper model loading, chunked transcription inference, sending text back to Swift.

---

## Project Structure

```
reel_transcriber/
├── CLAUDE.md
├── .gitignore
├── reel_transcriber.py          # Old CLI (keep as-is)
├── requirements.txt             # Old CLI deps
└── LiveScribe/
    ├── MacApp/                  # Xcode project
    │   ├── LiveScribe.xcodeproj
    │   ├── project.yml          # xcodegen spec — re-run to regenerate project
    │   └── LiveScribe/
    │       ├── LiveScribeApp.swift        # @main entry point
    │       ├── AppDelegate.swift          # Launches Python subprocess, reads READY signal
    │       ├── StatusBarController.swift  # State machine, icon, popover management
    │       ├── Views/
    │       │   └── PopoverView.swift      # SwiftUI: transcript text, status, buttons
    │       ├── Audio/
    │       │   └── AudioCaptureManager.swift  # ScreenCaptureKit + AVAudioConverter
    │       ├── IPC/
    │       │   └── TranscriptionClient.swift  # WebSocket client, protocol handling
    │       └── Resources/
    │           ├── Info.plist             # LSUIElement=YES, NSScreenCaptureUsageDescription
    │           └── LiveScribe.entitlements
    └── PythonServer/
        ├── server.py            # asyncio WebSocket server, audio buffering
        ├── transcriber.py       # mlx-whisper / faster-whisper wrapper
        ├── test_client.py       # Integration test: sends sine wave, checks transcript
        ├── requirements.txt
        └── venv/                # Python venv (not committed)
```

---

## Key Technical Decisions

### Audio Capture: ScreenCaptureKit
- Use `SCStream` with `capturesAudio = true` in `SCStreamConfiguration`
- No third-party virtual audio driver (no BlackHole, no Soundflower)
- Requires "Screen Recording" permission — prompt user on first launch
- `NSScreenCaptureUsageDescription` in Info.plist is required
- macOS 13.0+ minimum

### Audio Resampling: AVAudioConverter in Swift
- ScreenCaptureKit returns 48 kHz stereo float32
- Whisper requires 16 kHz mono float32
- `AVAudioConverter` downsamples and mixes to mono in one pass
- Resampling done in Swift before sending bytes to Python

### IPC: WebSocket on localhost
- Python runs `websockets` server on `ws://127.0.0.1:8765`
- Swift connects with `URLSessionWebSocketTask`
- **Binary frames**: raw float32 audio data (16 kHz mono, little-endian)
- **Text frames**: JSON control + transcript messages
- Swift buffers ~3 seconds of audio (48,000 samples) then sends as one binary frame

### Transcription: mlx-whisper (primary) / faster-whisper (fallback)
- On Apple Silicon: `mlx-whisper` with `mlx-community/whisper-small-mlx`
- On Intel: `faster-whisper` with `small` model, `int8` compute type
- Backend auto-detected at startup via `platform.machine() == "arm64"`
- **Chunk size**: 3 seconds → transcribe → return text → repeat
- **Overlap**: 0.5 s of previous chunk prepended to avoid cutting words at boundaries

### UI: NSStatusItem + NSPopover + SwiftUI
- `LSUIElement = YES` in Info.plist (no Dock icon, menu bar only)
- `NSStatusItem` with SF Symbol icons that change per state
- `NSPopover` containing `NSHostingController<PopoverView>`
- `NSEvent` global monitor closes popover on outside click

### File Output
- Saved to `~/Documents/LiveScribe/YYYY-MM-DD_HH-MM-SS.txt`
- Directory created on first save if absent

---

## WebSocket Protocol

All text frames are JSON. Binary frames are raw float32 audio.

**Swift → Python (text):**
```json
{ "type": "start" }
{ "type": "stop" }
```

**Swift → Python (binary):** Raw `[Float32]` bytes — one 3-second chunk (48,000 samples at 16 kHz).

**Python → Swift (text):**
```json
{ "type": "ready" }
{ "type": "transcript", "text": "Hello world", "is_final": false }
{ "type": "error", "message": "Model failed to load" }
```

Note: the server currently only signals readiness via stdout `READY` (read by AppDelegate). The `{"type":"ready"}` WebSocket message is handled in TranscriptionClient but not yet emitted by the server — a no-op for now.

---

## App State Machine

```
IDLE ──(click)──► STARTING ──(READY on stdout)──► IDLE (ready to click)
                                                       │
                                                    (click)
                                                       │
                                                  LISTENING ──(Stop & Save)──► SAVING ──► SAVED ──(3s)──► IDLE
```

- **IDLE**: Waveform icon, normal. Click opens popover and starts listening.
- **STARTING**: "Connecting…" — Python not ready yet (shown on cold launch before READY)
- **LISTENING**: Red icon, live text scrolling, "Stop & Save" button
- **SAVING / SAVED**: File path shown for 3 s then back to IDLE
- **ERROR**: Red triangle icon, error message, Retry button

---

## Python Server Startup

AppDelegate launches `server.py` as a subprocess on app start. It reads two env vars (set in the Xcode scheme for development, bundled paths for release):

| Env var | Purpose |
|---|---|
| `LIVESCRIBE_SERVER_SCRIPT` | Absolute path to `server.py` |
| `LIVESCRIBE_PYTHON_BIN` | Absolute path to venv `python3` binary |

The server prints `READY` to stdout when the WebSocket is up and the model is loaded. AppDelegate's stdout pipe handler detects this and calls `statusBarController.pythonServerIsReady()`.

---

## Known SDK Gotchas

- **`SCStreamConfiguration.excludesCurrentProcessAudioFromCapture`** — added in macOS 14.2, not in the macOS 13 SDK. Removed from `AudioCaptureManager.swift`; not needed since the app produces no audio.
- **`AVAudioFormat(cmAudioFormatDescription:)`** — returns non-optional `AVAudioFormat` in current SDK; do not use `guard let`.
- **`@MainActor` propagation** — `AudioCaptureManager` is `@MainActor`, so both `AppDelegate` and `StatusBarController` must also be marked `@MainActor` to call its methods without wrapping in `Task`.
- **`websockets` 12+ deprecation** — `WebSocketServerProtocol` type annotation removed. Use untyped `websocket` parameter in handler functions.

---

## Permissions

| Permission | Why | Where set |
|---|---|---|
| Screen Recording | ScreenCaptureKit audio capture | System Settings → Privacy |
| `NSScreenCaptureUsageDescription` | Info.plist usage string | Info.plist |
| `LSUIElement = YES` | Hide from Dock | Info.plist |
| `com.apple.security.app-sandbox = NO` | Subprocess launch + local sockets | Entitlements |

---

## Requirements

**macOS**: 13.0 (Ventura) or later
**Hardware**: Apple Silicon strongly recommended; Intel supported via faster-whisper
**Xcode**: 15+
**Python**: 3.11+

**Python environment setup:**
```bash
cd LiveScribe/PythonServer
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

---

## Development Workflow

The Xcode scheme already has `LIVESCRIBE_SERVER_SCRIPT` and `LIVESCRIBE_PYTHON_BIN` set (via `project.yml` → regenerated into the scheme). So the full workflow is:

1. Open `LiveScribe/MacApp/LiveScribe.xcodeproj` in Xcode
2. Hit ⌘R — the app launches, AppDelegate starts the Python server automatically
3. Grant Screen Recording permission when the dialog appears (first run only)
4. Click the waveform icon in the menu bar
5. Play some audio — transcript should appear in the popover
6. Click "Stop & Save" — file written to `~/Documents/LiveScribe/`

To run the integration test independently:
```bash
cd LiveScribe/PythonServer
source venv/bin/activate
python test_client.py   # server must already be running on port 8765
```

To regenerate the Xcode project after editing `project.yml`:
```bash
cd LiveScribe/MacApp
xcodegen generate
```

---

## Next Steps

- First live run: open in Xcode, hit ⌘R, test with real audio
- Observe latency and transcript quality with `whisper-small`; tune chunk size / model if needed
- Polish: icon pulse animation during listening, popover min-height, edge cases
- Robustness: Python server crash recovery, port-in-use retry, audio permission denied UI
