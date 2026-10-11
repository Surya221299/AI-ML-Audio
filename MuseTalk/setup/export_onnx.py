"""
Export MuseTalk core models to ONNX for CoreML inference on Apple Silicon.
Exports: UNet (mouth inpainting), VAE encoder, VAE decoder.
Timestep is baked to 0 (MuseTalk uses a fixed timestep); VAE scaling folded in.
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


def export_unet():
    cfg = json.load(open(MODELS_DIR / "musetalkV15/musetalk.json"))
    model = UNet2DConditionModel(**cfg)
    sd = torch.load(MODELS_DIR / "musetalkV15/unet.pth", map_location="cpu")
    model.load_state_dict(sd)
    model.eval()

    class Wrap(nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m
            self.register_buffer("timestep", torch.tensor([0], dtype=torch.long))

        def forward(self, sample, audio):
            return self.m(sample, self.timestep, encoder_hidden_states=audio).sample

    w = Wrap(model).eval()
    sample = torch.randn(1, 8, 32, 32)
    audio = torch.randn(1, 50, 384)
    with torch.no_grad():
        torch.onnx.export(
            w, (sample, audio), str(OUT / "unet.onnx"),
            input_names=["sample", "audio"], output_names=["latent"],
            dynamic_axes={"sample": {0: "B"}, "audio": {0: "B", 1: "S"}, "latent": {0: "B"}},
            opset_version=OPSET, dynamo=False,
        )
    print("✓ unet.onnx")


def export_vae():
    vae = AutoencoderKL.from_pretrained(MODELS_DIR / "sd-vae")
    vae.eval()
    sf = float(vae.config.scaling_factor)

    class Enc(nn.Module):
        def __init__(self, v, sf):
            super().__init__(); self.v = v; self.sf = sf
        def forward(self, img):  # img in [-1,1], [B,3,256,256]
            return self.sf * self.v.encode(img).latent_dist.mean

    class Dec(nn.Module):
        def __init__(self, v, sf):
            super().__init__(); self.v = v; self.sf = sf
        def forward(self, latent):  # [B,4,32,32] -> image in [-1,1]
            return self.v.decode((1.0 / self.sf) * latent).sample

    with torch.no_grad():
        torch.onnx.export(
            Enc(vae, sf).eval(), torch.randn(1, 3, 256, 256), str(OUT / "vae_encoder.onnx"),
            input_names=["image"], output_names=["latent"],
            dynamic_axes={"image": {0: "B"}, "latent": {0: "B"}}, opset_version=OPSET, dynamo=False,
        )
        print("✓ vae_encoder.onnx")
        torch.onnx.export(
            Dec(vae, sf).eval(), torch.randn(1, 4, 32, 32), str(OUT / "vae_decoder.onnx"),
            input_names=["latent"], output_names=["image"],
            dynamic_axes={"latent": {0: "B"}, "image": {0: "B"}}, opset_version=OPSET, dynamo=False,
        )
        print("✓ vae_decoder.onnx")


if __name__ == "__main__":
    export_vae()
    export_unet()
    print("\nDONE — exported to", OUT.resolve())
