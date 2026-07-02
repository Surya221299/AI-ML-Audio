"""
VoxCPM2 RunPod Serverless handler — cloud twin of server_mlx.py's /speak.

Called via RunPod's job API:
    POST https://api.runpod.ai/v2/{ENDPOINT_ID}/runsync
    Authorization: Bearer {API_KEY}
    {"input": {"text": "...", "emotion": "", ...}}
  → {"output": {"audio_b64": "<base64 wav>", "gen_s": .., "audio_s": .., "rtf": ..}}

The WAV is base64 because RunPod job output is JSON, not raw bytes.
Model loads once at import so it stays warm across requests on the same worker.
(torch.compile is disabled via ENV in the Dockerfile — VoxCPM2's fullgraph
compile hits a fatal dynamo graph break on einops; eager runs fine.)
"""
import base64
import io
import time

import soundfile as sf
import runpod
from voxcpm import VoxCPM

REF_AUDIO = "/assets/ref_voice.wav"

model = VoxCPM(
    voxcpm_model_path="/models/VoxCPM2",
    enable_denoiser=False,
    device="cuda",
)


def handler(job):
    inp = job.get("input", {})
    text = (inp.get("text") or "").strip()
    if not text:
        return {"error": "text is empty"}

    emotion = (inp.get("emotion") or "").strip()
    # raw voxcpm steers emotion via a "(emotion) text" prefix (same as run_emotion.py)
    prompt = f"({emotion}) {text}" if emotion else text

    t0 = time.perf_counter()
    audio = model.generate(
        text=prompt,
        reference_wav_path=REF_AUDIO,
        cfg_value=inp.get("cfg_value", 2.5),
        inference_timesteps=inp.get("inference_timesteps", 10),
        max_len=inp.get("max_tokens", 2000),
    )
    gen_s = time.perf_counter() - t0

    sr = model.tts_model.sample_rate
    audio_s = len(audio) / sr
    buf = io.BytesIO()
    sf.write(buf, audio, sr, format="WAV", subtype="PCM_16")

    return {
        "audio_b64": base64.b64encode(buf.getvalue()).decode(),
        "gen_s": round(gen_s, 3),
        "audio_s": round(audio_s, 3),
        "rtf": round(gen_s / audio_s, 3) if audio_s > 0 else None,
    }


runpod.serverless.start({"handler": handler})
