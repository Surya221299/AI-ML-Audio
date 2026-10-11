"""
Compatibility shim for legacy `python MuseTalk/musetalk_server.py`.
Points to `backend.lipsync.server`.
"""

import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
if str(root) not in sys.path:
    sys.path.insert(0, str(root))

from backend.lipsync.server import main

if __name__ == "__main__":
    main()
