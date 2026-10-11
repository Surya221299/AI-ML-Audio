"""
VoxCPM2 MLX Backend Server — Port 8808 (Apple Silicon optimized).
Endpoints: /health, /speak, /speak_stream, /config

Refactored:
- Dead SadTalker code removed
- Config and audio utilities modularized
- Fully compatible with InterviewTime iOS client
"""

import asyncio
import io
import logging
import queue
import struct
import threading
import time
from pathlib import Path
from typing import Optional

import numpy as np
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from backend.core.config import (
    MODELS_DIR,
    REF_VOICE_PATH,
    TTS_HOST,
    TTS_PORT,
    DEFAULT_TTS_CONFIG,
    STREAM_TTS_CONFIG,
)
from backend.core.audio_utils import normalize_audio, pad_start_audio, audio_to_wav_bytes

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("TTS-MLX")

app = FastAPI(title="VoxCPM2-MLX-TTS", version="2.0.0")

# Candidate model paths: local weights first, fallback to Hugging Face
MODEL_CANDIDATES = [
    str(MODELS_DIR / "VoxCPM2-8bit"),
    "mlx-community/VoxCPM2-8bit",
]

# Tunable generation config
TTS_CONFIG = dict(DEFAULT_TTS_CONFIG)

# Reference voice anchor
REF_AUDIO = REF_VOICE_PATH if REF_VOICE_PATH and Path(REF_VOICE_PATH).exists() else None
if REF_AUDIO:
    logger.info(f"Using reference voice: {REF_AUDIO}")
else:
    logger.warning("No reference voice found. Voice timbre will rely on defaults.")

# Model state
model = None
MODEL_ID = None
SAMPLE_RATE = 48000

try:
    from mlx_audio.tts import load_model

    for candidate in MODEL_CANDIDATES:
        logger.info(f"Attempting to load MLX model: {candidate}...")
        try:
            model = load_model(candidate)
            MODEL_ID = candidate
            SAMPLE_RATE = model.sample_rate
            logger.info(f"✓ Loaded {MODEL_ID}. Sample rate: {SAMPLE_RATE} Hz")
            break
        except Exception as e:
            logger.warning(f"Could not load {candidate}: {e}")

    if model is None:
        logger.error("No MLX TTS model could be loaded!")
    else:
        logger.info("Warming up MLX TTS model...")
        t0 = time.perf_counter()
        try:
            for _ in model.generate(text="Halo", max_tokens=50, inference_timesteps=2):
                pass
            logger.info(f"✓ Warmup complete in {time.perf_counter() - t0:.1f}s")
        except Exception as e:
            logger.warning(f"Warmup non-fatal error: {e}")

except ImportError:
    logger.warning("mlx_audio is not installed in this environment. MLX server will start with model=None.")


class SpeakRequest(BaseModel):
    text: str
    emotion: str = ""
    voice: Optional[str] = None
    cfg_value: Optional[float] = Field(None, ge=1.0, le=10.0)
    inference_timesteps: Optional[int] = Field(None, ge=1, le=50)
    max_tokens: Optional[int] = Field(None, ge=100, le=5000)
    warmup_patches: Optional[int] = Field(None, ge=0, le=20)


class ConfigUpdate(BaseModel):
    cfg_value: Optional[float] = Field(None, ge=0.0, le=10.0)
    inference_timesteps: Optional[int] = Field(None, ge=1, le=50)
    max_tokens: Optional[int] = Field(None, ge=100, le=5000)
    warmup_patches: Optional[int] = Field(None, ge=0, le=20)


def _gen_kwargs(
    text: str,
    emotion: str,
    ref_audio: Optional[str] = None,
    cfg_value: Optional[float] = None,
    inference_timesteps: Optional[int] = None,
    max_tokens: Optional[int] = None,
    warmup_patches: Optional[int] = None,
) -> dict:
    kwargs = {
        "text": text,
        "cfg_value": cfg_value if cfg_value is not None else TTS_CONFIG["cfg_value"],
        "inference_timesteps": (
            inference_timesteps if inference_timesteps is not None else TTS_CONFIG["inference_timesteps"]
        ),
        "max_tokens": max_tokens if max_tokens is not None else TTS_CONFIG["max_tokens"],
        "warmup_patches": (
            warmup_patches if warmup_patches is not None else TTS_CONFIG["warmup_patches"]
        ),
    }
    if ref_audio:
        kwargs["ref_audio"] = ref_audio
    if emotion and emotion.strip():
        kwargs["instruct"] = emotion.strip()
    return kwargs


@app.get("/health")
def health():
    if model is None:
        raise HTTPException(503, "MLX TTS model not loaded")
    return {
        "status": "ok",
        "engine": "mlx",
        "model": MODEL_ID,
        "sample_rate": SAMPLE_RATE,
        "config": TTS_CONFIG,
    }


@app.get("/config")
def get_config():
    return {"config": TTS_CONFIG}


@app.post("/config")
def set_config(update: ConfigUpdate):
    changed = {}
    for key in ("cfg_value", "inference_timesteps", "max_tokens", "warmup_patches"):
        val = getattr(update, key)
        if val is not None:
            old = TTS_CONFIG[key]
            TTS_CONFIG[key] = val
            changed[key] = {"old": old, "new": val}
    logger.info(f"[config] updated: {changed}")
    return {"config": TTS_CONFIG, "changed": changed}


@app.post("/speak")
def speak(req: SpeakRequest):
    """
    Standard full WAV synthesis endpoint consumed by InterviewTime iOS client.
    """
    if model is None:
        raise HTTPException(503, "Model not loaded")
    text = req.text.strip()
    if not text:
        raise HTTPException(400, "text is empty")

    logger.info(f"[speak] {text[:60]}")
    try:
        segments = [
            np.array(seg.audio, dtype=np.float32).squeeze()
            for seg in model.generate(
                **_gen_kwargs(
                    text,
                    req.emotion,
                    ref_audio=REF_AUDIO,
                    cfg_value=req.cfg_value,
                    inference_timesteps=req.inference_timesteps,
                    max_tokens=req.max_tokens,
                    warmup_patches=req.warmup_patches,
                )
            )
        ]
        if not segments:
            raise RuntimeError("Model produced no audio")

        combined = np.concatenate(segments)
        audio = pad_start_audio(normalize_audio(combined), sample_rate=SAMPLE_RATE)
        wav_bytes = audio_to_wav_bytes(audio, sample_rate=SAMPLE_RATE)

        return StreamingResponse(io.BytesIO(wav_bytes), media_type="audio/wav")

    except Exception as e:
        logger.error(f"[speak] failed: {e}")
        raise HTTPException(500, str(e))


@app.post("/speak_stream")
async def speak_stream(req: SpeakRequest):
    """
    Streams full concatenated audio chunks with 8-byte LE header.
    Header: [sample_rate: uint32 LE, channels: uint32 LE]
    Body: raw float32 PCM (mono)
    """
    if model is None:
        raise HTTPException(503, "Model not loaded")
    text = req.text.strip()
    if not text:
        raise HTTPException(400, "text is empty")

    logger.info(f"[speak_stream] {text[:60]}")
    q: queue.Queue = queue.Queue(maxsize=1)

    def run_model():
        try:
            segments = []
            for seg in model.generate(
                **_gen_kwargs(
                    text,
                    req.emotion,
                    ref_audio=REF_AUDIO,
                    cfg_value=req.cfg_value if req.cfg_value is not None else STREAM_TTS_CONFIG["cfg_value"],
                    inference_timesteps=(
                        req.inference_timesteps
                        if req.inference_timesteps is not None
                        else STREAM_TTS_CONFIG["inference_timesteps"]
                    ),
                    max_tokens=req.max_tokens if req.max_tokens is not None else STREAM_TTS_CONFIG["max_tokens"],
                    warmup_patches=(
                        req.warmup_patches
                        if req.warmup_patches is not None
                        else STREAM_TTS_CONFIG["warmup_patches"]
                    ),
                )
            ):
                chunk = np.array(seg.audio, dtype=np.float32).squeeze()
                if chunk.ndim == 0:
                    chunk = chunk.reshape(1)
                if chunk.ndim > 1:
                    chunk = chunk.mean(axis=0)
                segments.append(chunk)

            if segments:
                combined = np.concatenate(segments)
                audio = pad_start_audio(normalize_audio(combined), sample_rate=SAMPLE_RATE)
                q.put(audio.tobytes())
            q.put(None)  # sentinel EOF
        except Exception as e:
            logger.error(f"[speak_stream] error: {e}")
            q.put(e)

    loop = asyncio.get_event_loop()
    threading.Thread(target=run_model, daemon=True).start()

    async def generator():
        yield struct.pack("<II", SAMPLE_RATE, 1)
        while True:
            item = await loop.run_in_executor(None, q.get)
            if item is None:
                break
            if isinstance(item, Exception):
                logger.error(f"[speak_stream] stream error: {item}")
                break
            yield item

    return StreamingResponse(generator(), media_type="application/octet-stream")


if __name__ == "__main__":
    uvicorn.run(app, host=TTS_HOST, port=TTS_PORT, log_level="info")
