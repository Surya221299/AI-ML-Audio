"""
VoxCPM2 on Modal (Cloud T4 GPU) — Cloud endpoint for InterviewTime TTS.

Test (ephemeral, no persistent billing):
    modal run backend/tts/modal_app.py --text "Halo selamat datang di interview."

Deploy persistent endpoint:
    modal deploy backend/tts/modal_app.py
"""

from pathlib import Path
import modal

BACKEND_DIR = Path(__file__).resolve().parent.parent
PROJECT_ROOT = BACKEND_DIR.parent
REF_AUDIO_LOCAL = str(PROJECT_ROOT / "InterviewTime/Assets.xcassets/Audio/Gemala.dataset/Gemala.wav")
REF_AUDIO_REMOTE = "/assets/ref_voice.wav"

app = modal.App("interviewtime-voxcpm2")

image = (
    modal.Image.debian_slim(python_version="3.11")
    .apt_install("ffmpeg")
    .pip_install("voxcpm", "fastapi", "soundfile", "numpy")
    .run_commands(
        "python -c \"from huggingface_hub import snapshot_download; "
        "snapshot_download('openbmb/VoxCPM2', local_dir='/models/VoxCPM2')\""
    )
)

if Path(REF_AUDIO_LOCAL).exists():
    image = image.add_local_file(REF_AUDIO_LOCAL, REF_AUDIO_REMOTE)


@app.cls(gpu="T4", image=image, scaledown_window=300, timeout=600)
class VoxCPM2Server:
    @modal.enter()
    def load(self):
        import os
        os.environ["TORCH_COMPILE_DISABLE"] = "1"
        os.environ["TORCHDYNAMO_DISABLE"] = "1"
        import torch._dynamo
        torch._dynamo.config.disable = True
        from voxcpm import VoxCPM

        self.model = VoxCPM(
            voxcpm_model_path="/models/VoxCPM2",
            enable_denoiser=False,
            device="cuda",
        )

    def _speak(self, text: str, emotion: str = "", cfg_value: float = 2.5,
               inference_timesteps: int = 10, max_tokens: int = 2000):
        import io
        import time
        import numpy as np
        import soundfile as sf

        text = text.strip()
        if not text:
            raise ValueError("text is empty")
        prompt = f"({emotion.strip()}) {text}" if emotion.strip() else text

        t0 = time.perf_counter()
        ref_path = REF_AUDIO_REMOTE if Path(REF_AUDIO_REMOTE).exists() else None
        audio = self.model.generate(
            text=prompt,
            reference_wav_path=ref_path,
            cfg_value=cfg_value,
            inference_timesteps=inference_timesteps,
            max_len=max_tokens,
        )
        gen_s = time.perf_counter() - t0
        sr = getattr(self.model.tts_model, "sample_rate", 48000)

        # Padding & Normalize
        audio_arr = np.array(audio, dtype=np.float32)
        if len(audio_arr) > 0:
            m = np.max(np.abs(audio_arr))
            if m > 1e-8:
                audio_arr = audio_arr * (0.92 / m)
            pad = np.zeros(int(sr * 0.35), dtype=audio_arr.dtype)
            audio_arr = np.concatenate([pad, audio_arr])

        audio_s = len(audio_arr) / sr
        rtf = gen_s / audio_s if audio_s > 0 else float("nan")

        buf = io.BytesIO()
        sf.write(buf, audio_arr, sr, format="WAV", subtype="PCM_16")
        return buf.getvalue(), gen_s, audio_s, rtf

    @modal.method()
    def speak(self, text: str, emotion: str = "", cfg_value: float = 2.5,
              inference_timesteps: int = 10, max_tokens: int = 2000):
        return self._speak(text, emotion, cfg_value, inference_timesteps, max_tokens)

    @modal.asgi_app()
    def web(self):
        from fastapi import FastAPI, HTTPException
        from fastapi.responses import Response
        from pydantic import BaseModel

        web_app = FastAPI()

        class SpeakRequest(BaseModel):
            text: str
            emotion: str = ""
            voice: str = ""
            cfg_value: float = 2.5
            inference_timesteps: int = 10
            max_tokens: int = 2000
            warmup_patches: int = 0

        @web_app.get("/health")
        def health():
            return {"status": "ok"}

        @web_app.post("/speak")
        def speak_endpoint(req: SpeakRequest):
            try:
                wav_bytes, gen_s, audio_s, rtf = self._speak(
                    req.text, req.emotion, req.cfg_value,
                    req.inference_timesteps, req.max_tokens,
                )
            except ValueError as e:
                raise HTTPException(400, str(e))
            return Response(
                content=wav_bytes,
                media_type="audio/wav",
                headers={
                    "X-Gen-Seconds": f"{gen_s:.3f}",
                    "X-Audio-Seconds": f"{audio_s:.3f}",
                    "X-RTF": f"{rtf:.3f}",
                },
            )

        return web_app


@app.local_entrypoint()
def main(
    text: str = "Selamat datang, silakan perkenalkan diri Anda.",
    emotion: str = "",
    out: str = "/tmp/modal_voxcpm2_test.wav",
):
    wav_bytes, gen_s, audio_s, rtf = VoxCPM2Server().speak.remote(text, emotion)
    with open(out, "wb") as f:
        f.write(wav_bytes)
    print(f"Saved {out} (gen={gen_s:.2f}s, audio={audio_s:.2f}s, RTF={rtf:.3f})")
