"""
Compatibility shim for legacy `python server_mlx.py` invocations.
Points directly to `backend.tts.server_mlx`.
"""

import sys
from pathlib import Path

# Ensure workspace root is in sys.path
root = Path(__file__).resolve().parent
if str(root) not in sys.path:
    sys.path.insert(0, str(root))

from backend.tts.server_mlx import app, uvicorn, TTS_HOST, TTS_PORT

if __name__ == "__main__":
    uvicorn.run(app, host=TTS_HOST, port=TTS_PORT, log_level="info")
