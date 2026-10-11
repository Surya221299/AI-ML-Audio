"""
MuseTalk LipSync Server — Port 8810.
Endpoints:
  GET  /health
  POST /lipsync
  POST /lipsync_stream

Supports both Apple Silicon CoreML and Cloud GPU PyTorch modes.
"""

import cgi
import json
import logging
import os
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional

from backend.core.config import LIPSYNC_HOST, LIPSYNC_PORT, BACKEND_DIR, is_cuda_available
from backend.lipsync.pipeline import LipSyncPipeline

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("LipSync-Server")

PORT = LIPSYNC_PORT
HOST = LIPSYNC_HOST
BASE = Path(__file__).resolve().parent
PKG_DIRS = [
    BASE / "mlpackage",
    BACKEND_DIR.parent / "MuseTalk" / "mlpackage",
]


def load_coreml_models():
    import coremltools as ct
    target_pkg = None
    for d in PKG_DIRS:
        if (d / "unet.mlpackage").exists():
            target_pkg = d
            break

    if target_pkg is None:
        return None

    models = {}
    for name in ["vae_encoder", "unet", "vae_decoder"]:
        path = target_pkg / f"{name}.mlpackage"
        if not path.exists():
            return None
        print(f"[LipSync] Loading CoreML {name}.mlpackage from {path}...", flush=True)
        t0 = time.perf_counter()
        models[name] = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.ALL)
        print(f"[LipSync]  → Loaded in {time.perf_counter()-t0:.1f}s", flush=True)
    return models


class Handler(BaseHTTPRequestHandler):
    pipeline: Optional[LipSyncPipeline] = None
    render_lock = threading.Lock()

    def log_message(self, fmt, *args):
        pass  # suppress noisy access log

    def _send_json(self, code: int, obj: dict):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"status": "ok", "port": PORT})
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/lipsync_stream":
            self._handle_stream()
            return
        if self.path != "/lipsync":
            self.send_response(404)
            self.end_headers()
            return

        try:
            form = cgi.FieldStorage(
                fp=self.rfile,
                headers=self.headers,
                environ={
                    "REQUEST_METHOD": "POST",
                    "CONTENT_TYPE": self.headers["Content-Type"],
                },
            )
            image_bytes = form.getvalue("image")
            audio_bytes = form.getvalue("audio")
            fps = int(form.getvalue("fps", 25))
            if not image_bytes or not audio_bytes:
                self._send_json(400, {"error": "Need 'image' and 'audio' fields"})
                return
        except Exception as e:
            self._send_json(400, {"error": f"Bad request: {e}"})
            return

        tmp = tempfile.mkdtemp(prefix="lipsync_req_")
        img_path = os.path.join(tmp, "source.png")
        wav_path = os.path.join(tmp, "audio.wav")
        out_path = os.path.join(tmp, "out.mp4")
        with open(img_path, "wb") as f:
            f.write(image_bytes)
        with open(wav_path, "wb") as f:
            f.write(audio_bytes)

        try:
            t0 = time.time()
            with self.render_lock:
                _, num_frames = self.pipeline.run(img_path, wav_path, out_path, fps=fps)
            dt = time.time() - t0
            print(f"/lipsync: {num_frames} frames in {dt:.1f}s ({num_frames/dt:.1f} fps)", flush=True)
        except Exception as e:
            import traceback
            traceback.print_exc()
            self._send_json(500, {"error": f"Render failed: {e}"})
            return

        data = Path(out_path).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _parse_inputs(self):
        form = cgi.FieldStorage(
            fp=self.rfile,
            headers=self.headers,
            environ={"REQUEST_METHOD": "POST", "CONTENT_TYPE": self.headers["Content-Type"]},
        )
        image_bytes = form.getvalue("image")
        audio_bytes = form.getvalue("audio")
        fps = int(form.getvalue("fps", 10))
        seg = int(form.getvalue("seg_frames", 10))
        if not image_bytes or not audio_bytes:
            raise ValueError("Need 'image' and 'audio' fields")
        return image_bytes, audio_bytes, fps, seg

    def _handle_stream(self):
        """Streams MP4 chunks as [4-byte big-endian length][mp4 bytes]...[len=0]."""
        try:
            image_bytes, audio_bytes, fps, seg = self._parse_inputs()
        except Exception as e:
            self._send_json(400, {"error": f"Bad request: {e}"})
            return

        tmp = tempfile.mkdtemp(prefix="lipsync_stream_")
        img_path = os.path.join(tmp, "source.png")
        wav_path = os.path.join(tmp, "audio.wav")
        with open(img_path, "wb") as f:
            f.write(image_bytes)
        with open(wav_path, "wb") as f:
            f.write(audio_bytes)

        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()

        try:
            t0 = time.time()
            n_seg = 0
            with self.render_lock:
                for mp4 in self.pipeline.run_segments(img_path, wav_path, fps=fps, seg_frames=seg):
                    self.wfile.write(len(mp4).to_bytes(4, "big"))
                    self.wfile.write(mp4)
                    self.wfile.flush()
                    if n_seg == 0:
                        print(f"/lipsync_stream: first segment in {time.time()-t0:.1f}s", flush=True)
                    n_seg += 1
            self.wfile.write((0).to_bytes(4, "big"))  # EOF marker
            self.wfile.flush()
            print(f"/lipsync_stream: {n_seg} segments in {time.time()-t0:.1f}s", flush=True)
        except (BrokenPipeError, ConnectionResetError):
            print("/lipsync_stream: client disconnected", flush=True)
        except Exception as e:
            import traceback
            traceback.print_exc()


def main():
    print(f"MuseTalk server starting on port {PORT}...", flush=True)

    coreml_models = None
    if sys.platform == "darwin":
        try:
            coreml_models = load_coreml_models()
        except Exception as e:
            print(f"[LipSync] Could not load CoreML models ({e}), falling back...", flush=True)

    if coreml_models is not None:
        print("[LipSync] Running with CoreML acceleration.", flush=True)
        Handler.pipeline = LipSyncPipeline(coreml_models=coreml_models)
    else:
        device = "cuda" if is_cuda_available() else "cpu"
        print(f"[LipSync] Running in PyTorch mode on {device}.", flush=True)
        Handler.pipeline = LipSyncPipeline(coreml_models=None, device=device)

    print(f"Ready — listening on http://{HOST}:{PORT}", flush=True)
    bind_host = "0.0.0.0" if HOST == "0.0.0.0" else "127.0.0.1"
    ThreadingHTTPServer((bind_host, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
