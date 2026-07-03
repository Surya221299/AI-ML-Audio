"""Compare a TTS output wav against a reference wav using PESQ + STOI.

Usage: python eval_tts.py reference.wav degraded.wav
"""
import sys
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly
from pesq import pesq
from pystoi import stoi

PESQ_SR = 16000  # pesq only supports 8k (narrowband) or 16k (wideband)


def load_mono(path, target_sr):
    audio, sr = sf.read(path, dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != target_sr:
        audio = resample_poly(audio, target_sr, sr)
    return audio


def evaluate(ref_path, deg_path, sr=PESQ_SR):
    ref = load_mono(ref_path, sr)
    deg = load_mono(deg_path, sr)
    n = min(len(ref), len(deg))
    ref, deg = ref[:n], deg[:n]

    pesq_score = pesq(sr, ref, deg, "wb")  # wideband; use "nb" at sr=8000
    stoi_score = stoi(ref, deg, sr, extended=False)
    return pesq_score, stoi_score


if __name__ == "__main__":
    ref_path, deg_path = sys.argv[1], sys.argv[2]
    p, s = evaluate(ref_path, deg_path)
    print(f"PESQ: {p:.3f}  (1=bad .. 4.5=excellent)")
    print(f"STOI: {s:.3f}  (0=bad .. 1=excellent)")
