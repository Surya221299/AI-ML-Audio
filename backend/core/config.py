"""
Central configuration for the backend services.
Supports environment variables for cloud and local deployments.
"""

import os
from pathlib import Path
from typing import Optional

# Base directory paths
BACKEND_DIR = Path(__file__).resolve().parent.parent
PROJECT_ROOT = BACKEND_DIR.parent
MODELS_DIR = Path(os.environ.get("MODELS_DIR", str(PROJECT_ROOT / "models")))

# Reference audio voice anchor (default to Gemala.wav)
DEFAULT_REF_VOICE = (
    PROJECT_ROOT / "InterviewTime" / "Assets.xcassets" / "Audio" / "Gemala.dataset" / "Gemala.wav"
)
REF_VOICE_PATH: Optional[str] = (
    os.environ.get("REF_VOICE_PATH") or (str(DEFAULT_REF_VOICE) if DEFAULT_REF_VOICE.exists() else None)
)

# Network settings
TTS_HOST = os.environ.get("TTS_HOST", "0.0.0.0")
TTS_PORT = int(os.environ.get("TTS_PORT", "8808"))

LIPSYNC_HOST = os.environ.get("LIPSYNC_HOST", "0.0.0.0")
LIPSYNC_PORT = int(os.environ.get("LIPSYNC_PORT", "8810"))

# Hardware & Engine auto-detection
def is_cuda_available() -> bool:
    try:
        import torch
        return torch.cuda.is_available()
    except ImportError:
        return False

def is_mlx_available() -> bool:
    try:
        import mlx.core
        return True
    except ImportError:
        return False

# Default TTS generation config
DEFAULT_TTS_CONFIG = {
    "cfg_value": 2.5,
    "inference_timesteps": 6,
    "max_tokens": 2000,
    "warmup_patches": 2,
}

# Stream-specific fast balanced defaults
STREAM_TTS_CONFIG = {
    "cfg_value": 2.0,
    "inference_timesteps": 4,
    "max_tokens": 2000,
    "warmup_patches": 0,
}
