"""
Convert MuseTalk PyTorch models → CoreML (.mlpackage) directly via coremltools.

Why not via ONNX: ONNX decomposes nn.LayerNorm into primitive ops (ReduceMean +
Sub + Mul + ReduceMean + Add + Sqrt + Div). ANE can't run fp16 Sqrt, so the whole
block falls back to CPU. coremltools converts nn.LayerNorm to CoreML's native
layer_norm op which ANE handles natively — unlocking full ANE acceleration.

Output: mlpackage/ directory with UNet, VAE encoder, VAE decoder.
"""
import json, os
from pathlib import Path
import torch
import torch.nn as nn
import coremltools as ct
from diffusers import UNet2DConditionModel, AutoencoderKL

MUSETALK_DIR = Path(__file__).resolve().parent.parent
MODELS_DIR   = MUSETALK_DIR.parent / "models"
OUT = MUSETALK_DIR / "mlpackage"
OUT.mkdir(exist_ok=True)

AUDIO_SEQ = 50   # fixed Whisper feature window


# ── Wrappers (same as ONNX export) ────────────────────────────────────────────

class UNetWrap(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
        self.register_buffer("ts", torch.tensor([0], dtype=torch.long))

    def forward(self, sample, audio):
        return self.m(sample, self.ts, encoder_hidden_states=audio).sample


class VAEEnc(nn.Module):
    def __init__(self, v, sf):
        super().__init__()
        self.v = v
        self.sf = sf

    def forward(self, img):
        return self.sf * self.v.encode(img).latent_dist.mean


class VAEDec(nn.Module):
    def __init__(self, v, sf):
        super().__init__()
        self.v = v
        self.sf = sf

    def forward(self, latent):
        return self.v.decode((1.0 / self.sf) * latent).sample


# ── Convert helpers ────────────────────────────────────────────────────────────

def _ct_convert(traced, inputs, name):
    path = str(OUT / f"{name}.mlpackage")
    print(f"  Converting to CoreML MLProgram (fp16)...", flush=True)
    model = ct.convert(
        traced,
        inputs=inputs,
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    print(f"  Saving → {path}", flush=True)
    model.save(path)
    size_mb = sum(f.stat().st_size for f in Path(path).rglob("*") if f.is_file()) / 1e6
    print(f"  ✓ {name}.mlpackage  ({size_mb:.0f} MB)", flush=True)
    return model


# ── UNet ──────────────────────────────────────────────────────────────────────

def export_unet():
    print("\n=== UNet ===")
    cfg = json.load(open(MODELS_DIR / "musetalkV15/musetalk.json"))
    base = UNet2DConditionModel(**cfg)
    sd = torch.load(MODELS_DIR / "musetalkV15/unet.pth", map_location="cpu")
    base.load_state_dict(sd)
    wrap = UNetWrap(base).eval()

    sample = torch.zeros(1, 8, 32, 32)
    audio  = torch.zeros(1, AUDIO_SEQ, 384)

    print("  Tracing...", flush=True)
    with torch.no_grad():
        traced = torch.jit.trace(wrap, (sample, audio))

    inputs = [
        ct.TensorType(name="sample", shape=sample.shape),
        ct.TensorType(name="audio",  shape=audio.shape),
    ]
    _ct_convert(traced, inputs, "unet")


# ── VAE ───────────────────────────────────────────────────────────────────────

def export_vae():
    print("\n=== VAE ===")
    vae = AutoencoderKL.from_pretrained(MODELS_DIR / "sd-vae")
    vae.eval()
    sf = float(vae.config.scaling_factor)

    img    = torch.zeros(1, 3, 256, 256)
    latent = torch.zeros(1, 4, 32, 32)

    print("  Tracing encoder...", flush=True)
    with torch.no_grad():
        traced_enc = torch.jit.trace(VAEEnc(vae, sf).eval(), img)
    _ct_convert(
        traced_enc,
        [ct.TensorType(name="image", shape=img.shape)],
        "vae_encoder",
    )

    print("  Tracing decoder...", flush=True)
    with torch.no_grad():
        traced_dec = torch.jit.trace(VAEDec(vae, sf).eval(), latent)
    _ct_convert(
        traced_dec,
        [ct.TensorType(name="latent", shape=latent.shape)],
        "vae_decoder",
    )


if __name__ == "__main__":
    export_vae()
    export_unet()
    print(f"\nDone — CoreML packages in {OUT.resolve()}")
    print("Next: run bench_coreml_mlpackage.py to benchmark with ANE.")
