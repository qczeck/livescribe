# LiveScribe

A macOS menu bar app that captures system audio and transcribes it live using Whisper — no cloud, no virtual audio drivers, no subscriptions.

Click the waveform icon → audio starts transcribing in real time → click Stop & Save → transcript written to `~/Documents/LiveScribe/`.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-primary-orange) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![Python](https://img.shields.io/badge/Python-3.11%2B-blue)

---

## How it works

Two-process architecture: a Swift app handles the UI and audio capture, a Python subprocess runs Whisper inference.

```
┌─────────────────────────────────────┐
│          Swift App (menu bar)       │
│  ScreenCaptureKit → AVAudioConverter│
│  48 kHz stereo → 16 kHz mono f32   │
│  URLSessionWebSocketTask (client)   │
└─────────────┬───────────────────────┘
              │  ws://127.0.0.1:8765
              │  binary: float32 audio chunks
              │  text:   JSON control + transcript
┌─────────────▼───────────────────────┐
│       Python Server (subprocess)    │
│  asyncio + websockets               │
│  mlx-whisper  (Apple Silicon)       │
│  faster-whisper (Intel fallback)    │
└─────────────────────────────────────┘
```

- **Audio**: captured via `ScreenCaptureKit` — no BlackHole or Soundflower needed
- **Model**: `whisper-small-mlx` on Apple Silicon (fast, runs on Neural Engine/GPU); `faster-whisper` int8 on Intel
- **Chunks**: 3-second audio windows transcribed independently with a small overlap
- **Output**: `~/Documents/LiveScribe/YYYY-MM-DD_HH-MM-SS.txt`

---

## Requirements

| Requirement | Detail |
|---|---|
| macOS | 13.0 (Ventura) or later |
| Hardware | Apple Silicon recommended; Intel supported |
| Xcode | 15+ |
| Python | 3.11+ |
| Permission | Screen Recording (System Settings → Privacy & Security) |

---

## Setup

```bash
git clone git@github.com:qczeck/livescribe.git
cd livescribe
bash install.sh
```

That's it. The script:
1. Checks Xcode and Python 3.11+ are installed
2. Creates a Python venv and installs dependencies
3. Writes `~/.config/livescribe/config` so the app finds the server when launched from `/Applications`
4. Builds `LiveScribe.app` with `xcodebuild` and copies it to `/Applications`

> **First transcription**: Whisper model weights (~500 MB for `small`) are downloaded from HuggingFace and cached. Subsequent launches are instant.

### Prerequisites

- **Xcode 15+** — install from the App Store, then open it once to accept the licence
- **Python 3.11+** — `brew install python@3.11` if needed

### Screen Recording permission

On first launch, macOS will prompt for Screen Recording access. Grant it, then click the menu bar icon. If the dialog doesn't appear, go to **System Settings → Privacy & Security → Screen Recording** and enable LiveScribe manually.

### If the build step fails

`xcodebuild` may fail if no code signing identity is configured. In that case:

1. Open `LiveScribe/MacApp/LiveScribe.xcodeproj` in Xcode
2. Go to the **LiveScribe** target → **Signing & Capabilities**
3. Set your Team
4. Hit **⌘R** — the app runs directly from Xcode

The `install.sh` script still sets up the Python environment and config file, so ⌘R works without any further manual steps.

---

## Running

Once installed, launch **LiveScribe** from `/Applications` like any other app.

1. Click the **waveform** icon in the menu bar
2. Play audio on your Mac — transcript appears in the popover in real time
3. Click **Stop & Save** — file written to `~/Documents/LiveScribe/`

The app lives in the menu bar only (no Dock icon). Click outside the popover to dismiss it without stopping.

---

## Project structure

```
├── README.md
├── CLAUDE.md                        # Full architecture notes
├── LiveScribe/
│   ├── MacApp/                      # Xcode project
│   │   ├── LiveScribe.xcodeproj
│   │   ├── project.yml              # xcodegen spec
│   │   └── LiveScribe/
│   │       ├── LiveScribeApp.swift
│   │       ├── AppDelegate.swift    # Subprocess launch, READY signal
│   │       ├── StatusBarController.swift  # State machine, icon
│   │       ├── Views/
│   │       │   └── PopoverView.swift      # SwiftUI transcript view
│   │       ├── Audio/
│   │       │   └── AudioCaptureManager.swift  # ScreenCaptureKit + resampling
│   │       ├── IPC/
│   │       │   └── TranscriptionClient.swift  # WebSocket client
│   │       └── Resources/
│   │           ├── Info.plist
│   │           └── LiveScribe.entitlements
│   └── PythonServer/
│       ├── server.py                # asyncio WebSocket server
│       ├── transcriber.py           # mlx-whisper / faster-whisper wrapper
│       ├── test_client.py           # Integration test
│       └── requirements.txt
```

---

## WebSocket protocol

All text frames are JSON. Binary frames are raw `float32` audio.

| Direction | Frame | Content |
|---|---|---|
| Swift → Python | text | `{"type": "start"}` / `{"type": "stop"}` |
| Swift → Python | binary | Raw float32 samples (16 kHz mono, little-endian) |
| Python → Swift | text | `{"type": "transcript", "text": "...", "is_final": false}` |
| Python → Swift | text | `{"type": "error", "message": "..."}` |

---

## Troubleshooting

**Bars / progress noise in Xcode console** — The HAL and `AddInstanceForFactory` lines are macOS audio subsystem internals. They are harmless and cannot be suppressed.

**`-layoutSubtreeIfNeeded` warning** — AppKit internal, harmless.

**Port 8765 in use** — AppDelegate kills any stale process on the port before launching. If it persists: `lsof -ti:8765 | xargs kill -9`.

**Python server not found** — Set `LIVESCRIBE_SERVER_SCRIPT` and `LIVESCRIBE_PYTHON_BIN` env vars in the Xcode scheme, or let the app find the bundled paths automatically.

**Screen Recording denied** — The app auto-retries once after 1.5 s. If it still fails, toggle the permission off and back on in System Settings and relaunch.

---

## License

MIT
