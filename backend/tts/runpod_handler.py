"""
RunPod Serverless Handler for VoxCPM2 TTS.
Directly compatible with InterviewTime's RunPodTTSClient.swift.

Deployed as a RunPod Serverless worker:
  input: {
    "text": "...",
    "emotion": "...",
    "voice": "...",
    "cfg_value": 2.5,
    "inference_timesteps": 6,
    "max_tokens": 200,
    "warmup_patches": 2
  }
  output: {
    "audio_b64": "<base64-encoded-wav>"
  }
"""

import os
import time
import numpy as np

from backend.core.config import MODELS_DIR, REF_VOICE_PATH
from backend.core.audio_utils import (
    normalize_audio,
    pad_start_audio,
    audio_to_wav_bytes,
    wav_bytes_to_base64,
)

# Global model instance
model = None
SAMPLE_RATE = 48000
REF_AUDIO = REF_VOICE_PATH if (REF_VOICE_PATH and os.path.exists(REF_VOICE_PATH)) else None


def load_model():
    global model, SAMPLE_RATE
    if model is not None:
        return model

    import torch
    os.environ["TORCH_COMPILE_DISABLE"] = "1"
    os.environ["TORCHDYNAMO_DISABLE"] = "1"
    try:
        import torch._dynamo
        torch._dynamo.config.disable = True
    except Exception:
        pass

    from voxcpm import VoxCPM

    model_path = os.environ.get("VOXCPM_MODEL_PATH", str(MODELS_DIR / "VoxCPM2"))
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"[RunPod] Loading VoxCPM2 from {model_path} onto {device}...", flush=True)
    model = VoxCPM(
        voxcpm_model_path=model_path,
        enable_denoiser=False,
        device=device,
    )
    SAMPLE_RATE = getattr(model.tts_model, "sample_rate", 48000)
    print(f"[RunPod] ✓ Model loaded successfully (SR: {SAMPLE_RATE} Hz).", flush=True)
    return model


def handler(job):
    """RunPod serverless job handler."""
    job_input = job.get("input", {})
    text = job_input.get("text", "").strip()
    if not text:
        return {"error": "Parameter 'text' is required and cannot be empty."}

    emotion = job_input.get("emotion", "").strip()
    cfg_value = float(job_input.get("cfg_value", 2.5))
    inference_timesteps = int(job_input.get("inference_timesteps", 6))
    max_tokens = int(job_input.get("max_tokens", 2000))

    prompt = f"({emotion}) {text}" if emotion else text

    try:
        t0 = time.perf_counter()
        m = load_model()
        audio = m.generate(
            text=prompt,
            reference_wav_path=REF_AUDIO,
            cfg_value=cfg_value,
            inference_timesteps=inference_timesteps,
            max_len=max_tokens,
        )
        gen_s = time.perf_counter() - t0

        audio_arr = np.array(audio, dtype=np.float32)
        audio_padded = pad_start_audio(normalize_audio(audio_arr), sample_rate=SAMPLE_RATE)
        wav_bytes = audio_to_wav_bytes(audio_padded, sample_rate=SAMPLE_RATE)
        b64_str = wav_bytes_to_base64(wav_bytes)

        print(f"[RunPod] Completed generation in {gen_s:.2f}s", flush=True)
        return {
            "audio_b64": b64_str,
            "gen_seconds": round(gen_s, 3),
        }
    except Exception as e:
        import traceback
        traceback.print_exc()
        return {"error": str(e)}


if __name__ == "__main__":
    try:
        import runpod
        # Warmup model ahead of first request
        load_model()
        runpod.serverless.start({"handler": handler})
    except ImportError:
        print("Runpod library not installed. To test standalone, run test call:")
        m = load_model()
        res = handler({"input": {"text": "Halo, ini uji coba RunPod serverless."}})
        print("Test result keys:", list(res.keys()))
