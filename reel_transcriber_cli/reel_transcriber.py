#!/usr/bin/env python3
"""
Instagram Reel Transcriber
Usage: python reel_transcriber.py --url <reel_url> -o output.txt

Backend by device:
  cpu  / cuda  →  faster-whisper  (CTranslate2)
  mps          →  mlx-whisper     (Apple MLX, M-series only)
"""

import argparse
import os
import sys
import tempfile
from pathlib import Path


# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

def format_time(seconds: float) -> str:
    m, s = divmod(int(seconds), 60)
    return f"[{m:02d}:{s:02d}]"


def set_hf_token(token: str | None) -> None:
    """
    Set the HuggingFace token so the Hub client stops warning about
    unauthenticated requests.  Priority: CLI arg > env var already set.
    """
    if token:
        os.environ["HF_TOKEN"] = token
    # If HF_TOKEN is already in the environment, nothing to do.
    # Either way, silence the "unauthenticated" warning explicitly:
    os.environ.setdefault("HF_HUB_DISABLE_IMPLICIT_TOKEN", "1")


# ─────────────────────────────────────────────
# 1. Download
# ─────────────────────────────────────────────

def download_reel(url: str, output_dir: str) -> str:
    """
    Download an Instagram reel to output_dir using yt-dlp.
    Returns the path to the downloaded audio file.
    """
    try:
        import yt_dlp
    except ImportError:
        sys.exit("❌  yt-dlp not installed. Run: pip install yt-dlp")

    output_template = os.path.join(output_dir, "reel.%(ext)s")

    ydl_opts = {
        # Prefer best audio-only stream; fall back to best video+audio
        "format": "bestaudio/best",
        "outtmpl": output_template,
        # Convert to mp3 for Whisper (requires ffmpeg)
        "postprocessors": [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": "mp3",
            "preferredquality": "192",
        }],
        "quiet": False,
        # Suppress harmless API noise (e.g. "No csrf token set by Instagram API")
        "no_warnings": True,
        # Instagram sometimes requires a logged-in session.
        # Uncomment and point to your cookies file if you hit auth errors:
        # "cookiefile": "/path/to/instagram_cookies.txt",
    }

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        ydl.download([url])

    audio_path = os.path.join(output_dir, "reel.mp3")
    if not os.path.exists(audio_path):
        # yt-dlp may use a different extension if ffmpeg isn't available
        candidates = list(Path(output_dir).glob("reel.*"))
        if not candidates:
            sys.exit("❌  Download failed — no output file found.")
        audio_path = str(candidates[0])

    return audio_path


# ─────────────────────────────────────────────
# 2a. Transcribe — faster-whisper (cpu / cuda)
# ─────────────────────────────────────────────

def _run_faster_whisper(
    audio_path: str,
    model_size: str,
    device: str,
    language: str | None,
    timestamps: bool,
) -> str:
    try:
        from faster_whisper import WhisperModel
    except ImportError:
        sys.exit("❌  faster-whisper not installed. Run: pip install faster-whisper")

    compute_type = "float16" if device == "cuda" else "int8"
    model = WhisperModel(model_size, device=device, compute_type=compute_type)

    print("🎙️  Transcribing …")
    segments, info = model.transcribe(
        audio_path,
        language=language,
        beam_size=5,
        vad_filter=True,
        vad_parameters={"min_silence_duration_ms": 500},
    )

    print(f"📝  Detected language: {info.language} ({info.language_probability:.0%})")

    if timestamps:
        lines = [f"{format_time(s.start)} {s.text.strip()}" for s in segments]
        return "\n".join(lines)
    else:
        return " ".join(s.text.strip() for s in segments)


# ─────────────────────────────────────────────
# 2b. Transcribe — mlx-whisper (mps / Apple Silicon)
# ─────────────────────────────────────────────

# mlx-whisper uses slightly different model name strings than faster-whisper.
_MLX_MODEL_MAP = {
    "tiny":     "mlx-community/whisper-tiny-mlx",
    "base":     "mlx-community/whisper-base-mlx",
    "small":    "mlx-community/whisper-small-mlx",
    "medium":   "mlx-community/whisper-medium-mlx",
    "large-v2": "mlx-community/whisper-large-v2-mlx",
    "large-v3": "mlx-community/whisper-large-v3-mlx",
}

def _run_mlx_whisper(
    audio_path: str,
    model_size: str,
    language: str | None,
    timestamps: bool,
) -> str:
    try:
        import mlx_whisper
    except ImportError:
        sys.exit(
            "❌  mlx-whisper not installed.\n"
            "    Run: pip install mlx-whisper\n"
            "    (Requires Apple Silicon — M1/M2/M3/M4)"
        )

    mlx_model = _MLX_MODEL_MAP.get(model_size, _MLX_MODEL_MAP["large-v3"])
    print(f"    MLX model: {mlx_model}")

    print("🎙️  Transcribing …")
    result = mlx_whisper.transcribe(
        audio_path,
        path_or_hf_repo=mlx_model,
        language=language,       # None → auto-detect
        word_timestamps=False,
        verbose=False,
    )

    detected = result.get("language", "unknown")
    print(f"📝  Detected language: {detected}")

    if timestamps:
        lines = []
        for seg in result.get("segments", []):
            ts = format_time(seg["start"])
            lines.append(f"{ts} {seg['text'].strip()}")
        return "\n".join(lines)
    else:
        return result.get("text", "").strip()


# ─────────────────────────────────────────────
# 2. Dispatch
# ─────────────────────────────────────────────

def transcribe(
    audio_path: str,
    model_size: str,
    device: str,
    language: str | None,
    timestamps: bool,
) -> str:
    print(f"\n🔄  Loading Whisper model '{model_size}' on {device} …")

    if device == "mps":
        return _run_mlx_whisper(audio_path, model_size, language, timestamps)
    else:
        return _run_faster_whisper(audio_path, model_size, device, language, timestamps)


# ─────────────────────────────────────────────
# 3. CLI
# ─────────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(
        description="Transcribe an Instagram reel to text.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # CPU (default)
  python reel_transcriber.py --url https://www.instagram.com/reel/DO8i05zlfV5/ -o transcript.txt

  # Apple Silicon (MPS via mlx-whisper — fastest on M-series)
  python reel_transcriber.py --url <url> -o out.txt --device mps

  # NVIDIA GPU
  python reel_transcriber.py --url <url> -o out.txt --device cuda

  # With timestamps, force English, keep audio
  python reel_transcriber.py --url <url> -o out.txt --timestamps --language en --keep-audio

  # Provide a HuggingFace token (or set HF_TOKEN env var)
  python reel_transcriber.py --url <url> -o out.txt --hf-token hf_xxxxxxxxxxxx
        """,
    )
    parser.add_argument("--url", required=True, help="Instagram reel URL")
    parser.add_argument("-o", "--output", required=True, help="Output text file path")
    parser.add_argument(
        "--model",
        default="large-v3",
        choices=["tiny", "base", "small", "medium", "large-v2", "large-v3"],
        help="Whisper model size (default: large-v3)",
    )
    parser.add_argument(
        "--device",
        default="cpu",
        choices=["cpu", "cuda", "mps"],
        help=(
            "Inference device (default: cpu). "
            "Use 'mps' for Apple Silicon — requires mlx-whisper. "
            "Use 'cuda' for NVIDIA — requires faster-whisper + CUDA."
        ),
    )
    parser.add_argument(
        "--language",
        default=None,
        help="Force a language code (e.g. 'en', 'pl'). Auto-detects if omitted.",
    )
    parser.add_argument(
        "--keep-audio",
        action="store_true",
        help="Keep the downloaded audio file alongside the output",
    )
    parser.add_argument(
        "--timestamps",
        action="store_true",
        help="Include [MM:SS] timestamps in the output",
    )
    parser.add_argument(
        "--hf-token",
        default=None,
        metavar="TOKEN",
        help=(
            "HuggingFace API token to avoid rate-limit warnings when "
            "downloading model weights. Can also be set via the HF_TOKEN "
            "environment variable."
        ),
    )
    return parser.parse_args()


def main():
    args = parse_args()

    # Apply HF token before anything touches huggingface_hub
    set_hf_token(args.hf_token)

    print(f"🎬  Downloading reel from:\n    {args.url}\n")

    with tempfile.TemporaryDirectory() as tmpdir:
        audio_path = download_reel(args.url, tmpdir)
        print(f"✅  Audio saved to: {audio_path}")

        if args.keep_audio:
            import shutil
            kept = Path(args.output).with_suffix(Path(audio_path).suffix)
            shutil.copy(audio_path, kept)
            print(f"🔊  Audio kept at: {kept}")

        transcript = transcribe(
            audio_path,
            model_size=args.model,
            device=args.device,
            language=args.language,
            timestamps=args.timestamps,
        )

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(transcript, encoding="utf-8")

    print(f"\n✅  Transcript saved to: {output_path}")
    print(f"\n{'─'*50}")
    preview = transcript[:500]
    print(preview + ("…" if len(transcript) > 500 else ""))
    print(f"{'─'*50}\n")


if __name__ == "__main__":
    main()