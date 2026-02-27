"""
transcriber.py — Whisper inference wrapper for LiveScribe.

Auto-selects backend:
  Apple Silicon (arm64) → mlx-whisper   (fast, native MLX)
  Intel / other         → faster-whisper (CTranslate2, int8)

Usage:
    t = Transcriber(model_size="small")
    text = t.transcribe(audio_np)  # audio_np: float32 numpy array, 16 kHz mono
"""

import platform
import sys
import numpy as np

SAMPLE_RATE = 16_000  # Hz — Whisper's native sample rate


def _is_apple_silicon() -> bool:
    return platform.system() == "Darwin" and platform.machine() == "arm64"


# ---------------------------------------------------------------------------
# MLX backend (Apple Silicon)
# ---------------------------------------------------------------------------

_MLX_MODEL_MAP = {
    "tiny":   "mlx-community/whisper-tiny-mlx",
    "base":   "mlx-community/whisper-base-mlx",
    "small":  "mlx-community/whisper-small-mlx",
    "medium": "mlx-community/whisper-medium-mlx",
    "large":  "mlx-community/whisper-large-v3-mlx",
}


class _MLXBackend:
    def __init__(self, model_size: str):
        try:
            import mlx_whisper  # noqa: F401
        except ImportError:
            sys.exit("mlx-whisper not installed. Run: pip install mlx-whisper")

        self._model_path = _MLX_MODEL_MAP.get(model_size, _MLX_MODEL_MAP["small"])
        self._mlx_whisper = __import__("mlx_whisper")
        print(f"[transcriber] MLX backend loaded: {self._model_path}", flush=True)

    def transcribe(self, audio: np.ndarray) -> str:
        result = self._mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self._model_path,
            language="en",
            verbose=None,   # None = silent; False paradoxically *enables* the tqdm bar
            word_timestamps=False,
        )
        return result.get("text", "").strip()


# ---------------------------------------------------------------------------
# faster-whisper backend (Intel / CUDA)
# ---------------------------------------------------------------------------

class _FasterWhisperBackend:
    def __init__(self, model_size: str):
        try:
            from faster_whisper import WhisperModel
        except ImportError:
            sys.exit("faster-whisper not installed. Run: pip install faster-whisper")

        self._model = WhisperModel(model_size, device="cpu", compute_type="int8")
        print(f"[transcriber] faster-whisper backend loaded: {model_size}", flush=True)

    def transcribe(self, audio: np.ndarray) -> str:
        segments, _ = self._model.transcribe(
            audio,
            language="en",
            beam_size=3,
            vad_filter=True,
            vad_parameters={"min_silence_duration_ms": 300},
        )
        return " ".join(s.text.strip() for s in segments)


# ---------------------------------------------------------------------------
# Public interface
# ---------------------------------------------------------------------------

class Transcriber:
    def __init__(self, model_size: str = "small"):
        if _is_apple_silicon():
            self._backend = _MLXBackend(model_size)
        else:
            self._backend = _FasterWhisperBackend(model_size)

    def transcribe(self, audio: np.ndarray) -> str:
        """
        Transcribe a chunk of audio.

        Args:
            audio: float32 numpy array, mono, 16 kHz sample rate.
                   Silence-only chunks return an empty string quickly.

        Returns:
            Transcribed text string (may be empty if no speech detected).
        """
        if audio.dtype != np.float32:
            audio = audio.astype(np.float32)

        # Normalise to [-1, 1] if needed
        peak = np.abs(audio).max()
        if peak > 1.0:
            audio = audio / peak

        return self._backend.transcribe(audio)
