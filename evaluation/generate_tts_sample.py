"""Generate a TTS wav cloned from Gemala's voice, for STOI/PESQ comparison
against evaluation/gemala_reference.wav. Uses the same model + defaults as
server_mlx.py's /speak endpoint.

Usage: python generate_tts_sample.py "text to speak" out.wav
"""
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
from mlx_audio.tts import load_model

PROJECT_ROOT = Path(__file__).parent.parent
REF_AUDIO = str(PROJECT_ROOT / "InterviewTime" / "Assets.xcassets" / "Audio" / "Gemala.dataset" / "Gemala.wav")

if __name__ == "__main__":
    text, out_path = sys.argv[1], sys.argv[2]

    model = load_model(str(PROJECT_ROOT / "models" / "VoxCPM2-8bit"))
    segments = [
        np.array(seg.audio, dtype=np.float32).squeeze()
        for seg in model.generate(
            text=text,
            ref_audio=REF_AUDIO,
            cfg_value=2.5,
            inference_timesteps=6,
            max_tokens=2000,
            warmup_patches=2,
        )
    ]
    audio = np.concatenate(segments)
    audio = audio * (0.92 / np.max(np.abs(audio)))
    sf.write(out_path, audio, model.sample_rate, format="WAV", subtype="PCM_16")
    print(f"wrote {out_path} ({len(audio) / model.sample_rate:.2f}s)")
