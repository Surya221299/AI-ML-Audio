"""
VoxCPM2 MLX backend — port 8808
Endpoints: /health, /speak, /speak_stream, /config
"""

import asyncio
import io
import logging
import queue
import struct
import subprocess
import tempfile
import threading
from pathlib import Path

import numpy as np
import soundfile as sf
import time

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse, JSONResponse
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="VoxCPM2-MLX")

PROJECT_ROOT = Path(__file__).parent
SADTALKER_DIR = PROJECT_ROOT / "SadTalker"
RESULTS_DIR   = SADTALKER_DIR / "results"

# Model candidates — use local bundled model first, fall back to HF download
MODEL_CANDIDATES = [
    str(PROJECT_ROOT / "models" / "VoxCPM2-8bit"),
    "mlx-community/VoxCPM2-8bit",
]

# ── Tunable generation config (can be changed at runtime via /config) ─────────
TTS_CONFIG = {
    "cfg_value":            2.5,     # VoxCPM2 minimum is 2.0; 2.5 reduces voice drift and robotic artifacts
    "inference_timesteps":  6,       # lowered from 10 for latency; still above stream's 4
    "max_tokens":           2000,    # default for VoxCPM2; allows longer utterances without truncation
    "warmup_patches":       2,       # silent patches that stabilise voice state before emitting audio
}

# ── Simple-TTS recipe (/speak_stream) — fast balanced defaults ───────────────
# The Swift view can override these per request. Kept separate so the MuseTalk
# (/speak) interviewer defaults and its latency are unaffected.
STREAM_CFG_VALUE = 2.5
STREAM_CFG_VALUE = 2.0
STREAM_TIMESTEPS = 4
STREAM_MAX_TOKENS = 2000
STREAM_WARMUP_PATCHES = 0

# ── Reference voice (anchors timbre so it doesn't drift mid-utterance) ────────
REF_VOICE_WAV = PROJECT_ROOT / "InterviewTime" / "Assets.xcassets" / "Audio" / "Gemala.dataset" / "Gemala.wav"
REF_AUDIO = str(REF_VOICE_WAV) if REF_VOICE_WAV.exists() else None

# ── Load model ────────────────────────────────────────────────────────────────
model = None
MODEL_ID = None
SAMPLE_RATE = 48000

from mlx_audio.tts import load_model

for candidate in MODEL_CANDIDATES:
    logger.info(f"Trying to load {candidate}...")
    try:
        model = load_model(candidate)
        MODEL_ID = candidate
        SAMPLE_RATE = model.sample_rate
        logger.info(f"✓ Loaded {MODEL_ID}. Sample rate: {SAMPLE_RATE} Hz")
        break
    except Exception as e:
        logger.warning(f"  Could not load {candidate}: {e}")

if model is None:
    logger.error("No model could be loaded!")

# ── Warmup — first run compiles MLX kernels (very slow without this) ──────────
if model is not None:
    logger.info("Warming up model (first run compiles MLX kernels)...")
    t0 = time.perf_counter()
    try:
        for _ in model.generate(text="Hello", max_tokens=50, inference_timesteps=2):
            pass
        logger.info(f"✓ Warmup done in {time.perf_counter() - t0:.1f}s")
    except Exception as e:
        logger.warning(f"Warmup failed (non-fatal): {e}")


class SpeakRequest(BaseModel):
    text: str
    emotion: str = ""
    generate_video: bool = False
    source_image: str = "examples/source_image/full_body_1.png"
    cfg_value: float | None = Field(None, ge=2.0, le=10.0)
    inference_timesteps: int | None = Field(None, ge=1, le=50)
    max_tokens: int | None = Field(None, ge=100, le=5000)
    warmup_patches: int | None = Field(None, ge=0, le=20)


def _gen_kwargs(text: str, emotion: str, ref_audio: str | None = None,
                cfg_value: float | None = None,
                inference_timesteps: int | None = None,
                max_tokens: int | None = None,
                warmup_patches: int | None = None) -> dict:
    kwargs = {
        "text": text,
        "cfg_value":           cfg_value if cfg_value is not None else TTS_CONFIG["cfg_value"],
        "inference_timesteps": inference_timesteps if inference_timesteps is not None else TTS_CONFIG["inference_timesteps"],
        "max_tokens":          max_tokens if max_tokens is not None else TTS_CONFIG["max_tokens"],
        "warmup_patches":      warmup_patches if warmup_patches is not None else TTS_CONFIG["warmup_patches"],
    }
    if ref_audio:
        kwargs["ref_audio"] = ref_audio   # voice-clone anchor → consistent timbre
    if emotion.strip():
        kwargs["instruct"] = emotion.strip()
    return kwargs


# ── Audio utils ───────────────────────────────────────────────────────────────

def _normalize(audio: np.ndarray, peak: float = 0.92) -> np.ndarray:
    """Scale so the loudest sample hits `peak` (0–1). Keeps relative dynamics."""
    m = np.max(np.abs(audio))
    return audio * (peak / m) if m > 1e-8 else audio

def _pad_start(audio: np.ndarray, ms: float = 350) -> np.ndarray:
    """Tambah keheningan di awal supaya onset huruf pertama tidak terpotong."""
    pad = np.zeros(int(SAMPLE_RATE * ms / 1000), dtype=audio.dtype)
    return np.concatenate([pad, audio])

# ── /health ───────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    if model is None:
        raise HTTPException(503, "Model not loaded")
    return {
        "status": "ok",
        "model": MODEL_ID,
        "sample_rate": SAMPLE_RATE,
        "config": TTS_CONFIG,
    }


# ── /config  (runtime tuning) ────────────────────────────────────────────────

class ConfigUpdate(BaseModel):
    cfg_value:           float | None = Field(None, ge=0.0, le=10.0)
    inference_timesteps: int   | None = Field(None, ge=1, le=50)
    max_tokens:          int   | None = Field(None, ge=100, le=5000)
    warmup_patches:      int   | None = Field(None, ge=0, le=20)

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


# ── /speak  (full WAV, blocking) ──────────────────────────────────────────────

@app.post("/speak")
def speak(req: SpeakRequest):
    if model is None:
        raise HTTPException(503, "Model not loaded")
    text = req.text.strip()
    if not text:
        raise HTTPException(400, "text is empty")

    logger.info(f"[speak] {text[:60]}")
    try:
        segments = [
            np.array(seg.audio, dtype=np.float32).squeeze()
            for seg in model.generate(**_gen_kwargs(
                text, req.emotion,
                ref_audio=REF_AUDIO,
                cfg_value=req.cfg_value,
                inference_timesteps=req.inference_timesteps,
                max_tokens=req.max_tokens,
                warmup_patches=req.warmup_patches,
            ))
        ]
        if not segments:
            raise RuntimeError("model produced no audio")
        # audio = _normalize(np.concatenate(segments))
        audio = _pad_start(_normalize(np.concatenate(segments)))

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            sf.write(tmp.name, audio, SAMPLE_RATE, format="WAV", subtype="PCM_16")
            audio_path = tmp.name

        video_path = None
        if req.generate_video:
            video_path = run_sadtalker(audio_path, req.source_image)

        with open(audio_path, "rb") as f:
            audio_data = f.read()
        Path(audio_path).unlink(missing_ok=True)

        if req.generate_video:
            return JSONResponse({
                "audio": audio_data.hex(),
                "video_path": str(video_path) if video_path else None,
            })

        return StreamingResponse(io.BytesIO(audio_data), media_type="audio/wav")

    except Exception as e:
        logger.error(f"[speak] failed: {e}")
        raise HTTPException(500, str(e))


# ── /speak_stream  (full generation, then stream — consistent voice) ──────────

@app.post("/speak_stream")
async def speak_stream(req: SpeakRequest):
    """
    Generates the full text in one pass, concatenates ALL segments into a single
    contiguous audio array, then streams the result. This avoids per-segment
    voice timbre changes that happen when segments are sent individually.

    Protocol:
      Header : 8 bytes — [sample_rate: uint32 LE, channels: uint32 LE]
      Body   : raw float32 PCM (mono), single contiguous block
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
            for seg in model.generate(**_gen_kwargs(
                text, req.emotion,
                ref_audio=REF_AUDIO,
                cfg_value=req.cfg_value if req.cfg_value is not None else STREAM_CFG_VALUE,
                inference_timesteps=(
                    req.inference_timesteps
                    if req.inference_timesteps is not None
                    else STREAM_TIMESTEPS
                ),
                max_tokens=req.max_tokens if req.max_tokens is not None else STREAM_MAX_TOKENS,
                warmup_patches=(
                    req.warmup_patches
                    if req.warmup_patches is not None
                    else STREAM_WARMUP_PATCHES
                ),
            )):
                chunk = np.array(seg.audio, dtype=np.float32).squeeze()
                if chunk.ndim == 0:
                    chunk = chunk.reshape(1)
                if chunk.ndim > 1:
                    chunk = chunk.mean(axis=0)
                segments.append(chunk)
            if segments:
                # audio = _normalize(np.concatenate(segments))
                audio = _pad_start(_normalize(np.concatenate(segments)))

                q.put(audio.tobytes())
            q.put(None)  # sentinel
        except Exception as e:
            logger.error(f"[speak_stream] model error: {e}")
            q.put(e)

    loop = asyncio.get_event_loop()
    threading.Thread(target=run_model, daemon=True).start()

    async def generator():
        yield struct.pack("<II", SAMPLE_RATE, 1)   # header: sample_rate, channels=1
        while True:
            item = await loop.run_in_executor(None, q.get)
            if item is None:
                break
            if isinstance(item, Exception):
                logger.error(f"[speak_stream] stream error: {item}")
                break
            yield item

    return StreamingResponse(generator(), media_type="application/octet-stream")


# ── SadTalker helper ──────────────────────────────────────────────────────────

def run_sadtalker(audio_path: str, source_image: str) -> Path | None:
    source_img = SADTALKER_DIR / source_image
    if not source_img.exists():
        logger.error(f"[SadTalker] source image not found: {source_img}")
        return None
    try:
        cmd = f"""
            cd "{SADTALKER_DIR}"
            source sadtalker-env/bin/activate
            python inference.py \
                --driven_audio "{audio_path}" \
                --source_image "{source_img}" \
                --result_dir "{RESULTS_DIR}" \
                --still --preprocess full --enhancer gfpgan
        """
        result = subprocess.run(cmd, shell=True, executable="/bin/zsh",
                                capture_output=True, text=True, timeout=300)
        if result.returncode != 0:
            logger.error(f"[SadTalker] {result.stderr}")
            return None
        mp4s = sorted(RESULTS_DIR.glob("*.mp4"), key=lambda p: p.stat().st_mtime)
        return mp4s[-1] if mp4s else None
    except Exception as e:
        logger.error(f"[SadTalker] {e}")
        return None


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8808, log_level="info")
