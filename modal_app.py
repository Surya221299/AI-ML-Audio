"""
VoxCPM2 on Modal (T4 GPU) — cloud twin of server_mlx.py's /speak.

Test (ephemeral, tears down after, no persistent billing):
    modal run modal_app.py --text "..."

Deploy for real (persistent endpoint, MuseTalkView -> Modal (cloud)):
    modal deploy modal_app.py
"""

import modal

REF_AUDIO_LOCAL = "InterviewTime/Assets.xcassets/Audio/Gemala.dataset/Gemala.wav"
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
    .add_local_file(REF_AUDIO_LOCAL, REF_AUDIO_REMOTE)
)


@app.cls(gpu="T4", image=image, scaledown_window=300, timeout=600)
class VoxCPM2Server:
    @modal.enter()
    def load(self):
        # VoxCPM2 runs inference under torch.compile(fullgraph=True); dynamo hits
        # a hard graph break on einops (_prepare_transformation_recipe) that is
        # fatal in fullgraph mode. Disable compilation entirely → run eager.
        # (T4 also can't compile bf16 natively, so we lose nothing here.)
        import os
        os.environ["TORCH_COMPILE_DISABLE"] = "1"
        os.environ["TORCHDYNAMO_DISABLE"] = "1"
        import torch._dynamo
        torch._dynamo.config.disable = True
        from voxcpm import VoxCPM
        # enable_denoiser=False: the local server doesn't use it either, and
        # skipping it means one less model to load on cold start.
        self.model = VoxCPM(
            voxcpm_model_path="/models/VoxCPM2",
            enable_denoiser=False,
            device="cuda",
        )

    def _speak(self, text: str, emotion: str = "", cfg_value: float = 2.5,
               inference_timesteps: int = 10, max_tokens: int = 2000):
        import time
        import io
        import soundfile as sf

        text = text.strip()
        if not text:
            raise ValueError("text is empty")
        # raw voxcpm has no separate emotion/instruct kwarg — it's steered
        # via a "(emotion) text" prefix, same convention as run_emotion.py.
        prompt = f"({emotion.strip()}) {text}" if emotion.strip() else text

        t0 = time.perf_counter()
        audio = self.model.generate(
            text=prompt,
            reference_wav_path=REF_AUDIO_REMOTE,
            cfg_value=cfg_value,
            inference_timesteps=inference_timesteps,
            max_len=max_tokens,
        )
        gen_s = time.perf_counter() - t0
        sr = self.model.tts_model.sample_rate
        audio_s = len(audio) / sr
        rtf = gen_s / audio_s if audio_s > 0 else float("nan")
        print(f"[speak] gen={gen_s:.2f}s audio={audio_s:.2f}s RTF={rtf:.3f}")

        buf = io.BytesIO()
        sf.write(buf, audio, sr, format="WAV", subtype="PCM_16")
        return buf.getvalue(), gen_s, audio_s, rtf

    @modal.method()
    def speak(self, text: str, emotion: str = "", cfg_value: float = 2.5,
              inference_timesteps: int = 10, max_tokens: int = 2000):
        """Used by `modal run` for ephemeral testing (see local_entrypoint below)."""
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
    text: str = (
        "Selamat datang dan terimakasih sudah datang di interview, "
        "kita mulai, bisa jelaskan tentang background diri anda?"
    ),
    emotion: str = "",
    out: str = "/tmp/modal_voxcpm2_test.wav",
):
    """`modal run modal_app.py` — ephemeral test, tears down after this returns."""
    wav_bytes, gen_s, audio_s, rtf = VoxCPM2Server().speak.remote(text, emotion)
    with open(out, "wb") as f:
        f.write(wav_bytes)
    print(f"Saved {out}")
    print(f"gen={gen_s:.2f}s  audio={audio_s:.2f}s  RTF={rtf:.3f}")
