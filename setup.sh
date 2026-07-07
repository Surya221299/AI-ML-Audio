#!/bin/zsh
# setup.sh — siapkan environment Python + download semua model.
# Jalankan sekali dari root repo: zsh setup.sh
# Aman dijalankan ulang (idempotent) — langkah yang sudah selesai akan dilewati.

set -u  # error kalau ada variabel yang belum di-set (typo-safe), tapi TIDAK exit paksa di tiap baris
cd "$(dirname "$0")"
ROOT="$(pwd)"

# Cetak pesan error yang jelas kalau ada langkah kritis gagal, lalu hentikan.
fail() { echo ""; echo "❌ Setup dihentikan: $1"; echo ""; exit 1; }

echo "==> [0/6] Cek prasyarat dasar..."
[[ "$(uname)" == "Darwin" ]] || fail "Script ini untuk macOS saja."
command -v python3 >/dev/null 2>&1 || fail "python3 tidak ditemukan. Install Python 3 dulu (mis. via https://python.org atau 'brew install python3')."
command -v curl >/dev/null 2>&1 || fail "curl tidak ditemukan (biasanya sudah ada di macOS)."

# Peringatan ruang disk (model ~10GB+), tidak menghentikan script.
AVAIL_GB=$(df -g "$ROOT" | tail -1 | awk '{print $4}')
if [[ "$AVAIL_GB" =~ ^[0-9]+$ ]] && (( AVAIL_GB < 15 )); then
  echo "⚠️  Ruang disk tersisa ~${AVAIL_GB}GB. Model butuh ~10-15GB. Lanjut, tapi awasi ruang disk."
fi

echo "==> [1/6] Menyiapkan environment MLX TTS (voxcpm-env)..."
if [ -d envs/voxcpm-env ]; then
  echo "    sudah ada, dilewati (hapus folder envs/voxcpm-env untuk buat ulang)."
else
  python3 -m venv envs/voxcpm-env || fail "gagal membuat venv voxcpm-env."
  envs/voxcpm-env/bin/pip install -q --upgrade pip
  envs/voxcpm-env/bin/pip install -q \
    mlx-audio fastapi uvicorn soundfile numpy pydantic \
    || fail "gagal install dependency voxcpm-env."
fi

echo "==> [2/6] Menyiapkan environment MuseTalk (musetalk-env)..."
if [ -d envs/musetalk-env ]; then
  echo "    sudah ada, dilewati (hapus folder envs/musetalk-env untuk buat ulang)."
else
  python3 -m venv envs/musetalk-env || fail "gagal membuat venv musetalk-env."
  envs/musetalk-env/bin/pip install -q --upgrade pip
  [ -f MuseTalk/requirements.txt ] || fail "MuseTalk/requirements.txt tidak ditemukan — jalankan dari root repo."
  envs/musetalk-env/bin/pip install -q -r MuseTalk/requirements.txt \
    || fail "gagal install requirements.txt MuseTalk."
  envs/musetalk-env/bin/pip install -q coremltools torch torchvision onnxruntime \
    || fail "gagal install coremltools/torch/onnxruntime."
fi

echo "==> [3/6] Download VoxCPM2-8bit (TTS)..."
if [ -f models/VoxCPM2-8bit/model.safetensors ]; then
  echo "    sudah ada, dilewati."
else
  mkdir -p models/VoxCPM2-8bit
  envs/voxcpm-env/bin/python -c "
from huggingface_hub import snapshot_download
snapshot_download('mlx-community/VoxCPM2-8bit', local_dir='models/VoxCPM2-8bit')
print('✓ VoxCPM2-8bit downloaded')
" || fail "gagal download VoxCPM2-8bit (cek koneksi internet)."
fi

echo "==> [4/6] Download bobot MuseTalk..."
mkdir -p models/musetalkV15 models/dwpose_onnx \
         models/face-parse-bisent models/sd-vae models/whisper
envs/musetalk-env/bin/pip install -q "huggingface_hub[cli]" gdown

if [ -f models/musetalkV15/unet.pth ]; then
  echo "    MuseTalk UNet sudah ada, dilewati."
else
  envs/musetalk-env/bin/huggingface-cli download TMElyralab/MuseTalk \
    --local-dir models \
    --include "musetalkV15/musetalk.json" "musetalkV15/unet.pth" \
    || fail "gagal download MuseTalk UNet."
fi

if [ -f models/sd-vae/diffusion_pytorch_model.bin ]; then
  echo "    SD VAE sudah ada, dilewati."
else
  envs/musetalk-env/bin/huggingface-cli download stabilityai/sd-vae-ft-mse \
    --local-dir models/sd-vae \
    --include "config.json" "diffusion_pytorch_model.bin" \
    || fail "gagal download SD VAE."
fi

if [ -f models/whisper/pytorch_model.bin ]; then
  echo "    Whisper tiny sudah ada, dilewati."
else
  envs/musetalk-env/bin/huggingface-cli download openai/whisper-tiny \
    --local-dir models/whisper \
    --include "config.json" "pytorch_model.bin" "preprocessor_config.json" \
    || fail "gagal download whisper-tiny."
fi

if [ -f models/dwpose_onnx/dw-ll_ucoco_384.onnx ]; then
  echo "    DWPose ONNX sudah ada, dilewati."
else
  envs/musetalk-env/bin/huggingface-cli download yzd-v/DWPose \
    --local-dir models/dwpose_onnx \
    --include "yolox_l.onnx" "dw-ll_ucoco_384.onnx" \
    || fail "gagal download DWPose ONNX."
fi

# Face parse BiSeNet — gdown (Google Drive) kadang kena limit kuota; jangan hentikan
# seluruh script kalau ini gagal, cukup peringatkan supaya user bisa retry manual.
if [ -f models/face-parse-bisent/79999_iter.pth ]; then
  echo "    Face-parse BiSeNet sudah ada, dilewati."
else
  envs/musetalk-env/bin/python -m gdown \
    154JgKpzCPW82qINcVieuPH3fZ2e0P812 \
    -O models/face-parse-bisent/79999_iter.pth \
    || echo "⚠️  Download face-parse BiSeNet gagal (kemungkinan limit kuota Google Drive). Coba lagi nanti dengan:
      envs/musetalk-env/bin/python -m gdown 154JgKpzCPW82qINcVieuPH3fZ2e0P812 -O models/face-parse-bisent/79999_iter.pth"
fi

if [ -f models/face-parse-bisent/resnet18-5c106cde.pth ]; then
  echo "    resnet18 sudah ada, dilewati."
else
  curl -fL https://download.pytorch.org/models/resnet18-5c106cde.pth \
    -o models/face-parse-bisent/resnet18-5c106cde.pth \
    || fail "gagal download resnet18-5c106cde.pth (cek koneksi internet)."
fi

echo "==> [5/6] Patch & symlink..."

# Patch: PyTorch 2.6 default weights_only=True mematahkan load .pth format lama.
RESNET="MuseTalk/musetalk/utils/face_parsing/resnet.py"
if [ -f "$RESNET" ]; then
  if ! grep -q "weights_only=False" "$RESNET"; then
    echo "    Patching resnet.py (weights_only=False)..."
    sed -i '' 's/torch.load(model_path)/torch.load(model_path, weights_only=False)/' "$RESNET" 2>/dev/null \
      || sed -i 's/torch.load(model_path)/torch.load(model_path, weights_only=False)/' "$RESNET"
  else
    echo "    resnet.py sudah dipatch, dilewati."
  fi
else
  echo "⚠️  $RESNET tidak ditemukan — lewati patch (cek apakah folder MuseTalk lengkap)."
fi

# Symlink: server chdir ke MuseTalk/ lalu mencari ./models/ — butuh symlink ke ../models.
if [ -e "MuseTalk/models" ]; then
  echo "    Symlink MuseTalk/models sudah ada, dilewati."
else
  ln -s ../models MuseTalk/models
  echo "    Symlink MuseTalk/models dibuat."
fi

# Entitlements: path absolut temporary-exception harus cocok lokasi checkout SETIAP orang.
# Auto-perbaiki supaya tidak kena "permission denied" saat render ke outputs/ (isu yang
# pernah kita alami — path hardcode ke Mac orang lain tidak akan cocok di Mac lain).
ENT="InterviewTime/InterviewTime.entitlements"
if [ -f "$ENT" ]; then
  if grep -q "<string>$ROOT/</string>" "$ENT"; then
    echo "    Entitlements path sudah cocok lokasi ini, dilewati."
  else
    echo "    Menyesuaikan path di InterviewTime.entitlements ke lokasi repo ini..."
    cp "$ENT" "$ENT.bak"
    python3 - "$ENT" "$ROOT" << 'PYEOF'
import sys, re
path, root = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
content = re.sub(
    r'(<key>com\.apple\.security\.temporary-exception\.files\.absolute-path\.read-write</key>\s*<array>\s*<string>).*?(</string>)',
    lambda m: m.group(1) + root + "/" + m.group(2),
    content, flags=re.DOTALL
)
with open(path, "w") as f:
    f.write(content)
PYEOF
    echo "    ✓ Path entitlements diarahkan ke: $ROOT/ (backup lama: $ENT.bak)"
  fi
else
  echo "⚠️  $ENT tidak ditemukan — lewati (pastikan buka project dari Xcode sekali dulu, atau cek path folder InterviewTime/)."
fi

echo "==> [6/6] Cek file penting lainnya..."
if grep -q "_pad_start" server_mlx.py 2>/dev/null; then
  echo "    server_mlx.py sudah punya fix padding awal audio."
else
  echo "⚠️  server_mlx.py BELUM punya fix padding awal audio (huruf pertama TTS bisa terpotong)."
  echo "    Tambahkan manual: fungsi _pad_start() + panggil setelah _normalize() di /speak dan /speak_stream."
fi

if [ ! -f outputs/idle_loop1.mp4 ] && [ ! -f outputs/idle_loop2.mp4 ]; then
  echo "ℹ️  Tidak ada file outputs/idle_loop*.mp4 — avatar akan pakai gambar diam (bukan wajib, opsional)."
fi

echo ""
echo "✅ Setup selesai."
echo ""
echo "Langkah berikutnya — export CoreML packages (sekali saja, ~10 menit):"
echo "  envs/musetalk-env/bin/python MuseTalk/setup/export_coreml.py"
echo ""
echo "Lalu jalankan server:"
echo "  zsh start.sh"
echo ""
echo "── PRASYARAT TAMBAHAN (di luar script ini) ──"
echo "1. Ollama (untuk LLM):"
echo "     brew install ollama   # atau unduh dari https://ollama.com"
echo "     ollama pull llama3.1:8b"
echo "     ollama serve          # biarkan jalan saat memakai app"
echo ""
echo "2. WhisperKit (untuk STT) — via Xcode:"
echo "     Buka InterviewTime.xcodeproj → File → Add Package Dependencies"
echo "     URL: https://github.com/argmaxinc/WhisperKit  (versi 1.0.0+)"
echo "     Tautkan produk 'WhisperKit' ke target InterviewTime."
echo ""
echo "3. (Opsional) Follow-up question via RunPod:"
echo "     Tidak perlu install apa pun — cukup isi RunPod endpoint ID + API key"
echo "     di layar setup app (toggle 'Aktifkan Follow-up Question')."