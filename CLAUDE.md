# LiveScribe v2 — macOS Menu Bar Audio Transcriber

## Project Overview

LiveScribe is a macOS menu bar app that captures system audio playing on the Mac and transcribes it live using Apple's Speech framework. Clicking the menu bar icon starts listening; clicking again stops and saves the transcript to a `.txt` file. The popover shows the rolling transcript in real time.

**v2.0** — Pure Swift. No Python, no external dependencies, no subprocess management. Single self-contained binary.

The old `reel_transcriber.py` CLI (Instagram reel download + transcribe) lives alongside this app and is kept as-is. The v1.0 Python server code lives in `LiveScribe/PythonServer/` (archived, not used by v2).

---

## Current Status

**Working end-to-end. Pure Swift, single-process.**

- Swift app with Speech framework transcription
- Xcode project builds clean
- `install.sh` — one-command build + install to /Applications
- No Python, no venv, no WebSocket, no subprocess

---

## Architecture

Single-process model: all in Swift.

```
┌──────────────────────────────────────────┐
│           Swift App (LiveScribe)         │
│                                          │
│  NSStatusItem (menu bar icon)            │
│       │                                  │
│  NSPopover ──► SwiftUI PopoverView       │
│       │        (live transcript)         │
│       │                                  │
│  AudioCaptureManager                     │
│  (ScreenCaptureKit → AVAudioConverter    │
│   48kHz stereo → 16kHz mono float32)     │
│       │                                  │
│  TranscriptionEngine (protocol)          │
│       │                                  │
│  SpeechTranscriber                       │
│  (SFSpeechRecognizer — on-device or      │
│   server mode with 55s restart cycle)    │
└──────────────────────────────────────────┘
```

**`TranscriptionEngine` protocol** allows swapping backends. Current: `SpeechTranscriber` (Apple Speech framework). Future: `WhisperKitTranscriber`.

---

## Project Structure

```
reel_transcriber/
├── CLAUDE.md
├── README.md
├── .gitignore
├── install.sh                   # One-command build + install script
├── uninstall.sh
└── LiveScribe/
    ├── MacApp/                  # Xcode project
    │   ├── LiveScribe.xcodeproj
    │   ├── project.yml          # xcodegen spec — re-run to regenerate project
    │   └── LiveScribe/
    │       ├── LiveScribeApp.swift           # @main entry point
    │       ├── AppDelegate.swift             # Minimal — creates StatusBarController
    │       ├── StatusBarController.swift     # State machine, icon, popover management
    │       ├── Views/
    │       │   └── PopoverView.swift         # SwiftUI: transcript text, status, buttons
    │       ├── Audio/
    │       │   └── AudioCaptureManager.swift # ScreenCaptureKit + AVAudioConverter
    │       ├── Transcription/
    │       │   ├── TranscriptionEngine.swift # Protocol for transcription backends
    │       │   └── SpeechTranscriber.swift   # SFSpeechRecognizer implementation
    │       └── Resources/
    │           ├── Info.plist
    │           └── LiveScribe.entitlements
    └── PythonServer/            # Archived v1 code (not used by v2)
        ├── server.py
        ├── transcriber.py
        ├── test_client.py
        └── requirements.txt
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
- Speech framework receives 16 kHz mono float32 via `AVAudioPCMBuffer`
- `AVAudioConverter` downsamples and mixes to mono in one pass
- Buffers delivered directly to `SpeechTranscriber.feedAudio()` — no chunking

### Transcription: SFSpeechRecognizer (Apple Speech Framework)
- **On-device preferred**: `requiresOnDeviceRecognition = true` when `supportsOnDeviceRecognition` is available — unlimited duration, no network
- **Server fallback**: if on-device unavailable, uses Apple's server with a 55-second restart cycle to stay under the 1-minute per-request limit
- Cumulative transcript: SFSpeechRecognizer returns the full recognized string (not incremental), so StatusBarController **replaces** `sessionTranscript` each time
- Cancellation errors (code 216) and "no speech" errors (code 1110) are silently ignored

### TranscriptionEngine Protocol
- `start()`, `stop()`, `feedAudio(AVAudioPCMBuffer)` + callback properties
- `SpeechTranscriber` conforms now; future `WhisperKitTranscriber` will too
- StatusBarController only knows the protocol

### UI: NSStatusItem + NSPopover + SwiftUI
- `LSUIElement = YES` in Info.plist (no Dock icon, menu bar only)
- `NSStatusItem` with SF Symbol icons that change per state
- `NSPopover` containing `NSHostingController<PopoverView>`
- `NSEvent` global monitor closes popover on outside click

### File Output
- Saved to `~/Documents/LiveScribe/YYYY-MM-DD_HH-MM-SS.txt`
- Directory created on first save if absent

---

## App State Machine

```
IDLE ──(click)──► LISTENING ──(Stop & Save)──► SAVING ──► SAVED ──(3s)──► IDLE
                                                                          │
                                                                       (error)
                                                                          │
                                                                        ERROR ──(Retry)──► IDLE
```

- **IDLE**: Waveform icon, normal. Click opens popover and starts listening.
- **LISTENING**: Red icon, live text scrolling, "Stop & Save" button
- **SAVING / SAVED**: File path shown for 3 s then back to IDLE
- **ERROR**: Red triangle icon, error message, Retry button, Privacy Settings link

No `.starting` state — Speech framework initializes instantly (no model loading delay).

---

## Known SDK Gotchas

- **`SCStreamConfiguration.excludesCurrentProcessAudioFromCapture`** — added in macOS 14.2, not in the macOS 13 SDK. Removed from `AudioCaptureManager.swift`; not needed since the app produces no audio.
- **`AVAudioFormat(cmAudioFormatDescription:)`** — returns non-optional `AVAudioFormat` in current SDK; do not use `guard let`.
- **`@MainActor` propagation** — `AudioCaptureManager` is `@MainActor`, so both `AppDelegate` and `StatusBarController` must also be marked `@MainActor` to call its methods without wrapping in `Task`.

---

## Permissions

| Permission | Why | Where set |
|---|---|---|
| Screen Recording | ScreenCaptureKit audio capture | System Settings → Privacy |
| Speech Recognition | SFSpeechRecognizer transcription | System Settings → Privacy |
| `NSScreenCaptureUsageDescription` | Info.plist usage string | Info.plist |
| `NSSpeechRecognitionUsageDescription` | Info.plist usage string | Info.plist |
| `LSUIElement = YES` | Hide from Dock | Info.plist |
| `com.apple.security.app-sandbox = NO` | Unsigned direct distribution | Entitlements |

---

## Requirements

**macOS**: 13.0 (Ventura) or later
**Xcode**: 15+

No Python. No external dependencies.

---

## Development Workflow

### Fresh clone
```bash
bash install.sh
```
Checks Xcode, builds, and installs to `/Applications`.

### Day-to-day dev (Xcode)
1. Open `LiveScribe/MacApp/LiveScribe.xcodeproj` in Xcode
2. Hit ⌘R
3. Grant Screen Recording + Speech Recognition on first run
4. Click the waveform icon, play audio, verify transcript

### Regenerate Xcode project
```bash
cd LiveScribe/MacApp
xcodegen generate
```

---

## Next Steps

- Polish: icon pulse animation during listening, popover min-height
- WhisperKit integration as alternative `TranscriptionEngine` for offline local inference
- Locale selection (currently hardcoded to en-US)
