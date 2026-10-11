"""
Unified TTS Server Launcher.
Auto-detects whether to run MLX (Apple Silicon) or CUDA (Cloud GPU).
"""

import sys
import logging
import uvicorn
from backend.core.config import is_cuda_available, is_mlx_available, TTS_HOST, TTS_PORT

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("TTS-Launcher")


def main():
    if is_mlx_available() and sys.platform == "darwin":
        logger.info("Apple Silicon MLX environment detected. Starting server_mlx...")
        from backend.tts.server_mlx import app
    elif is_cuda_available():
        logger.info("NVIDIA CUDA GPU environment detected. Starting server_cuda...")
        from backend.tts.server_cuda import app
    else:
        logger.warning("Neither MLX nor CUDA detected! Falling back to MLX server...")
        try:
            from backend.tts.server_mlx import app
        except Exception:
            from backend.tts.server_cuda import app

    uvicorn.run(app, host=TTS_HOST, port=TTS_PORT, log_level="info")


if __name__ == "__main__":
    main()
