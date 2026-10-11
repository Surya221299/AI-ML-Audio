"""
VoxCPM2 PyTorch/CUDA Backend Server — Port 8808 (Cloud GPU optimized).
Endpoints: /health, /speak, /speak_stream, /config

Runs on Linux with NVIDIA GPU (CUDA) for Cloud Pods/VMs/Docker deployments.
"""

import io
import logging
import os
import time
from pathlib import Path
from typing import Optional

import numpy as np
import soundfile as sf
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
)
from backend.core.audio_utils import normalize_audio, pad_start_audio, audio_to_wav_bytes

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("TTS-CUDA")

app = FastAPI(title="VoxCPM2-CUDA-TTS", version="2.0.0")

# Candidate model paths
MODEL_PATH = os.environ.get("VOXCPM_MODEL_PATH", str(MODELS_DIR / "VoxCPM2"))

TTS_CONFIG = dict(DEFAULT_TTS_CONFIG)
REF_AUDIO = REF_VOICE_PATH if REF_VOICE_PATH and Path(REF_VOICE_PATH).exists() else None

model = None
SAMPLE_RATE = 48000

try:
    import torch
    # VoxCPM eager inference optimizations
    os.environ["TORCH_COMPILE_DISABLE"] = "1"
    os.environ["TORCHDYNAMO_DISABLE"] = "1"
    try:
        import torch._dynamo
        torch._dynamo.config.disable = True
    except Exception:
        pass

    from voxcpm import VoxCPM

    device = "cuda" if torch.cuda.is_available() else "cpu"
    logger.info(f"Loading VoxCPM model from {MODEL_PATH} on {device}...")
    model = VoxCPM(
        voxcpm_model_path=MODEL_PATH,
        enable_denoiser=False,
        device=device,
    )
    SAMPLE_RATE = getattr(model.tts_model, "sample_rate", 48000)
    logger.info(f"✓ Loaded VoxCPM CUDA model. Sample rate: {SAMPLE_RATE} Hz")

except ImportError as e:
    logger.warning(f"voxcpm / torch not available in this env ({e}). CUDA server will start in stub mode.")
except Exception as e:
    logger.error(f"Failed to load VoxCPM model: {e}")


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


@app.get("/health")
def health():
    if model is None:
        raise HTTPException(503, "CUDA TTS model not loaded")
    return {
        "status": "ok",
        "engine": "cuda",
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
    return {"config": TTS_CONFIG, "changed": changed}


@app.post("/speak")
def speak(req: SpeakRequest):
    if model is None:
        raise HTTPException(503, "Model not loaded")
    text = req.text.strip()
    if not text:
        raise HTTPException(400, "text is empty")

    prompt = f"({req.emotion.strip()}) {text}" if req.emotion and req.emotion.strip() else text
    cfg = req.cfg_value if req.cfg_value is not None else TTS_CONFIG["cfg_value"]
    timesteps = req.inference_timesteps if req.inference_timesteps is not None else TTS_CONFIG["inference_timesteps"]
    max_len = req.max_tokens if req.max_tokens is not None else TTS_CONFIG["max_tokens"]

    logger.info(f"[speak-cuda] {text[:60]}")
    t0 = time.perf_counter()
    try:
        audio = model.generate(
            text=prompt,
            reference_wav_path=REF_AUDIO,
            cfg_value=cfg,
            inference_timesteps=timesteps,
            max_len=max_len,
        )
        gen_s = time.perf_counter() - t0
        audio_arr = np.array(audio, dtype=np.float32)
        audio_padded = pad_start_audio(normalize_audio(audio_arr), sample_rate=SAMPLE_RATE)
        wav_bytes = audio_to_wav_bytes(audio_padded, sample_rate=SAMPLE_RATE)

        return StreamingResponse(
            io.BytesIO(wav_bytes),
            media_type="audio/wav",
            headers={"X-Gen-Seconds": f"{gen_s:.3f}"},
        )
    except Exception as e:
        logger.error(f"[speak-cuda] error: {e}")
        raise HTTPException(500, str(e))


if __name__ == "__main__":
    uvicorn.run(app, host=TTS_HOST, port=TTS_PORT, log_level="info")
