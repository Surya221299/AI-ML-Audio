"""
Export MuseTalk models to ONNX with STATIC shapes for CoreML MLProgram.

The original export_onnx.py uses dynamic_axes which causes CoreML MLProgram
to fail with "unbounded dimension not supported". This script bakes fixed shapes:
  UNet:        sample=[1,8,32,32], audio=[1,50,384]  → latent=[1,4,32,32]
  VAE encoder: image=[1,3,256,256]                   → latent=[1,4,32,32]
  VAE decoder: latent=[1,4,32,32]                    → image=[1,3,256,256]

Exports in fp16 to stay under 2GB (avoids external-data files which CoreML can't load).
"""
import json
from pathlib import Path
import torch
import torch.nn as nn
from diffusers import UNet2DConditionModel, AutoencoderKL

MUSETALK_DIR = Path(__file__).resolve().parent.parent
MODELS_DIR   = MUSETALK_DIR.parent / "models"
OUT = MUSETALK_DIR / "onnx_models"
OUT.mkdir(exist_ok=True)
OPSET = 17

UNET_AUDIO_SEQ = 50   # Whisper feature window MuseTalk uses


def export_unet_static():
    cfg = json.load(open(MODELS_DIR / "musetalkV15/musetalk.json"))
    model = UNet2DConditionModel(**cfg)
    sd = torch.load(MODELS_DIR / "musetalkV15/unet.pth", map_location="cpu")
    model.load_state_dict(sd)
    model.eval().half()

    class Wrap(nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m
            self.register_buffer("timestep", torch.tensor([0], dtype=torch.long))

        def forward(self, sample, audio):
            return self.m(sample, self.timestep, encoder_hidden_states=audio).sample

    w = Wrap(model).eval()

    sample = torch.randn(1, 8, 32, 32, dtype=torch.float16)
    audio  = torch.randn(1, UNET_AUDIO_SEQ, 384, dtype=torch.float16)

    out_path = str(OUT / "unet_fp16_static.onnx")
    with torch.no_grad():
        torch.onnx.export(
            w, (sample, audio), out_path,
            input_names=["sample", "audio"],
            output_names=["latent"],
            # NO dynamic_axes — static shapes for CoreML MLProgram
            opset_version=OPSET,
            dynamo=False,
        )
    size_mb = Path(out_path).stat().st_size / 1e6
    print(f"✓ unet_fp16_static.onnx  ({size_mb:.0f} MB)")


def export_vae_static():
    vae = AutoencoderKL.from_pretrained(MODELS_DIR / "sd-vae")
    vae.eval().half()
    sf = float(vae.config.scaling_factor)

    class Enc(nn.Module):
        def __init__(self, v, sf):
            super().__init__()
            self.v = v
            self.sf = sf

        def forward(self, img):
            return self.sf * self.v.encode(img).latent_dist.mean

    class Dec(nn.Module):
        def __init__(self, v, sf):
            super().__init__()
            self.v = v
            self.sf = sf

        def forward(self, latent):
            return self.v.decode((1.0 / self.sf) * latent).sample

    img     = torch.randn(1, 3, 256, 256, dtype=torch.float16)
    latent  = torch.randn(1, 4, 32, 32, dtype=torch.float16)

    enc_path = str(OUT / "vae_encoder_fp16_static.onnx")
    dec_path = str(OUT / "vae_decoder_fp16_static.onnx")

    with torch.no_grad():
        torch.onnx.export(
            Enc(vae, sf).eval(), img, enc_path,
            input_names=["image"], output_names=["latent"],
            opset_version=OPSET, dynamo=False,
        )
        print(f"✓ vae_encoder_fp16_static.onnx  ({Path(enc_path).stat().st_size/1e6:.0f} MB)")

        torch.onnx.export(
            Dec(vae, sf).eval(), latent, dec_path,
            input_names=["latent"], output_names=["image"],
            opset_version=OPSET, dynamo=False,
        )
        print(f"✓ vae_decoder_fp16_static.onnx  ({Path(dec_path).stat().st_size/1e6:.0f} MB)")


if __name__ == "__main__":
    print("Exporting VAE (static fp16)...")
    export_vae_static()
    print("\nExporting UNet (static fp16)...")
    export_unet_static()
    print(f"\nDONE — outputs in {OUT.resolve()}")
    print("\nNext: run bench_coreml_static.py to compile + benchmark MLProgram")
