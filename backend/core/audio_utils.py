"""
Audio utilities for TTS and LipSync processing.
"""

import base64
import io
import numpy as np
import soundfile as sf


def normalize_audio(audio: np.ndarray, peak: float = 0.92) -> np.ndarray:
    """
    Scale audio so the loudest sample hits `peak` (0.0 to 1.0).
    Keeps relative dynamics while ensuring consistent loudness.
    """
    if len(audio) == 0:
        return audio
    m = np.max(np.abs(audio))
    return audio * (peak / m) if m > 1e-8 else audio


def pad_start_audio(audio: np.ndarray, sample_rate: int = 48000, ms: float = 350) -> np.ndarray:
    """
    Add initial silence padding to prevent first syllable onset clipping.
    """
    pad_len = int(sample_rate * ms / 1000)
    pad = np.zeros(pad_len, dtype=audio.dtype)
    return np.concatenate([pad, audio])


def audio_to_wav_bytes(audio: np.ndarray, sample_rate: int = 48000) -> bytes:
    """
    Encode numpy audio array to 16-bit PCM WAV bytes in-memory.
    """
    buf = io.BytesIO()
    sf.write(buf, audio, sample_rate, format="WAV", subtype="PCM_16")
    return buf.getvalue()


def wav_bytes_to_base64(wav_bytes: bytes) -> str:
    """
    Encode WAV bytes to base64 string (used by RunPod serverless responses).
    """
    return base64.b64encode(wav_bytes).decode("utf-8")


def base64_to_wav_bytes(b64_str: str) -> bytes:
    """
    Decode base64 string to WAV bytes.
    """
    return base64.b64decode(b64_str)
