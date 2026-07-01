#!/bin/zsh
# setup.sh — create envs + download all models
# Run once from the repo root: zsh setup.sh

set -e
cd "$(dirname "$0")"
ROOT="$(pwd)"

echo "==> [1/4] Creating MLX TTS environment (voxcpm-env)..."
python3 -m venv envs/voxcpm-env
envs/voxcpm-env/bin/pip install -q --upgrade pip
envs/voxcpm-env/bin/pip install -q \
  mlx-audio fastapi uvicorn soundfile numpy pydantic

echo "==> [2/4] Creating MuseTalk environment (musetalk-env)..."
python3 -m venv envs/musetalk-env
envs/musetalk-env/bin/pip install -q --upgrade pip
envs/musetalk-env/bin/pip install -q -r MuseTalk/requirements.txt
envs/musetalk-env/bin/pip install -q coremltools torch torchvision onnxruntime

echo "==> [3/4] Downloading VoxCPM2-8bit (TTS)..."
mkdir -p models/VoxCPM2-8bit
envs/voxcpm-env/bin/python -c "
from huggingface_hub import snapshot_download
snapshot_download('mlx-community/VoxCPM2-8bit', local_dir='models/VoxCPM2-8bit')
print('✓ VoxCPM2-8bit downloaded')
"

echo "==> [4/4] Downloading MuseTalk weights..."
mkdir -p models/musetalkV15 models/dwpose_onnx \
         models/face-parse-bisent models/sd-vae models/whisper

envs/musetalk-env/bin/pip install -q "huggingface_hub[cli]" gdown

# MuseTalk V1.5 UNet
envs/musetalk-env/bin/huggingface-cli download TMElyralab/MuseTalk \
  --local-dir models \
  --include "musetalkV15/musetalk.json" "musetalkV15/unet.pth"

# SD VAE
envs/musetalk-env/bin/huggingface-cli download stabilityai/sd-vae-ft-mse \
  --local-dir models/sd-vae \
  --include "config.json" "diffusion_pytorch_model.bin"

# Whisper tiny feature extractor (model weights loaded from HF cache at runtime)
envs/musetalk-env/bin/huggingface-cli download openai/whisper-tiny \
  --local-dir models/whisper \
  --include "config.json" "pytorch_model.bin" "preprocessor_config.json"

# DWPose ONNX — pipeline uses dwpose_onnx/ (yolox + pose estimator)
envs/musetalk-env/bin/huggingface-cli download yzd-v/DWPose \
  --local-dir models/dwpose_onnx \
  --include "yolox_l.onnx" "dw-ll_ucoco_384.onnx"

# Face parse BiSeNet
envs/musetalk-env/bin/python -m gdown \
  154JgKpzCPW82qINcVieuPH3fZ2e0P812 \
  -O models/face-parse-bisent/79999_iter.pth
curl -L https://download.pytorch.org/models/resnet18-5c106cde.pth \
  -o models/face-parse-bisent/resnet18-5c106cde.pth

echo ""
echo "✅ Setup complete."
echo ""
echo "Next step — export CoreML packages (first time only, takes ~10 min):"
echo "  envs/musetalk-env/bin/python MuseTalk/setup/export_coreml.py"
echo ""
echo "Then start servers:"
echo "  zsh start.sh"
