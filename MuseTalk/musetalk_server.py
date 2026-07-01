"""
MuseTalk CoreML inference server — port 8810.
Accepts WAV audio + source image, returns a lip-synced mp4.

Pipeline (see lipsync_pipeline.py):
  Whisper-tiny audio features → DWPose face crop → VAE encode masked+ref face →
  per-frame UNet (CoreML) → VAE decode (CoreML) → BiSeNet blend → ffmpeg mux.

CoreML nets run via coremltools .mlpackage (PyTorch → CoreML native layer_norm).
Run export_coreml.py first to build the mlpackage/ directory.
"""
import cgi
import json
import os
import tempfile
import threading    
import time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import coremltools as ct

from lipsync_pipeline import LipSyncPipeline

PORT = 8810
BASE = Path(__file__).parent
PKG_DIR = BASE / "mlpackage"


def load_coreml_models():
    models = {}
    for name in ["vae_encoder", "unet", "vae_decoder"]:
        path = PKG_DIR / f"{name}.mlpackage"
        if not path.exists():
            raise FileNotFoundError(f"Missing {path} — run export_coreml.py first")
        print(f"Loading {name}.mlpackage...", flush=True)
        t0 = time.perf_counter()
        models[name] = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.ALL)
        print(f"  → loaded in {time.perf_counter()-t0:.1f}s", flush=True)
    return models


class Handler(BaseHTTPRequestHandler):
    pipeline = None
    render_lock = threading.Lock()

    def log_message(self, fmt, *args):
        pass  # suppress default access log

    def _send_json(self, code, obj):
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
                self._send_json(400, {"error": "need 'image' and 'audio' fields"})
                return
        except Exception as e:
            self._send_json(400, {"error": f"bad request: {e}"})
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
            print(f"/lipsync: {num_frames} frames in {dt:.1f}s "
                  f"({num_frames/dt:.1f} fps)", flush=True)
        except Exception as e:
            import traceback
            traceback.print_exc()
            self._send_json(500, {"error": f"render failed: {e}"})
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
            environ={"REQUEST_METHOD": "POST",
                     "CONTENT_TYPE": self.headers["Content-Type"]},
        )
        image_bytes = form.getvalue("image")
        audio_bytes = form.getvalue("audio")
        fps = int(form.getvalue("fps", 10))
        seg = int(form.getvalue("seg_frames", 10))
        if not image_bytes or not audio_bytes:
            raise ValueError("need 'image' and 'audio' fields")
        return image_bytes, audio_bytes, fps, seg

    def _handle_stream(self):
        """Stream mp4 segments as [4-byte big-endian length][mp4 bytes]…[len=0]."""
        try:
            image_bytes, audio_bytes, fps, seg = self._parse_inputs()
        except Exception as e:
            self._send_json(400, {"error": f"bad request: {e}"})
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
                for mp4 in self.pipeline.run_segments(img_path, wav_path,
                                                       fps=fps, seg_frames=seg):
                    self.wfile.write(len(mp4).to_bytes(4, "big"))
                    self.wfile.write(mp4)
                    self.wfile.flush()
                    if n_seg == 0:
                        print(f"/lipsync_stream: first segment in "
                              f"{time.time()-t0:.1f}s", flush=True)
                    n_seg += 1
            self.wfile.write((0).to_bytes(4, "big"))  # EOF marker
            self.wfile.flush()
            print(f"/lipsync_stream: {n_seg} segments in {time.time()-t0:.1f}s",
                  flush=True)
        except (BrokenPipeError, ConnectionResetError):
            print("/lipsync_stream: client disconnected", flush=True)
        except Exception as e:
            import traceback
            traceback.print_exc()
            # Best-effort: connection is mid-stream, just drop it.


def main():
    print(f"MuseTalk server starting on port {PORT}...")
    print("Loading CoreML models (first run compiles MLProgram — may take 1-3 min)...")
    models = load_coreml_models()
    Handler.pipeline = LipSyncPipeline(models)
    print(f"Ready — listening on http://127.0.0.1:{PORT}", flush=True)
    # Threaded so /health stays responsive while a render is in flight.
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    os.chdir(BASE)
    main()
