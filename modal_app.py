"""
Compatibility shim for legacy `modal run modal_app.py`.
Points to `backend.tts.modal_app`.
"""

import sys
from pathlib import Path

root = Path(__file__).resolve().parent
if str(root) not in sys.path:
    sys.path.insert(0, str(root))

from backend.tts.modal_app import app, VoxCPM2Server, main

__all__ = ["app", "VoxCPM2Server", "main"]
