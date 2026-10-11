# AI-ML-Audio Backend

Layanan backend terpadu untuk sintesis suara (**VoxCPM2 TTS**) dan animasi bibir real-time (**MuseTalk LipSync**), dirancang untuk dapat berjalan secara lokal pada Apple Silicon (macOS) maupun di-deploy ke Cloud GPU (Docker, RunPod Serverless, Modal, AWS, GCP).

---

## 📁 Struktur Direktori

```
backend/
├── core/
│   ├── config.py              # Konfigurasi terpusat & auto-deteksi device/hardware
│   └── audio_utils.py         # Normalisasi audio, padding onset, format helper
├── tts/
│   ├── server.py              # Auto-detect launcher (MLX / CUDA)
│   ├── server_mlx.py          # FastAPI server MLX TTS (:8808) untuk Apple Silicon
│   ├── server_cuda.py         # FastAPI server PyTorch/CUDA (:8808) untuk Cloud GPU
│   ├── modal_app.py           # Deployment script untuk Modal (Cloud T4 GPU)
│   └── runpod_handler.py      # RunPod Serverless handler (kompatibel dengan RunPodTTSClient.swift)
├── lipsync/
│   ├── server.py              # HTTP server MuseTalk (:8810) (CoreML & PyTorch CUDA)
│   ├── pipeline.py            # Lip-sync generation & streaming generator
│   ├── dwpose_onnx.py         # Detektor landmark wajah DWPose ONNX
│   ├── musetalk/              # Modul inti MuseTalk (UNet, VAE, utils, face parsing)
│   └── setup/
│       └── export_coreml.py   # Script export CoreML untuk macOS
├── Dockerfile                 # Image CUDA 12.1 production-ready untuk Cloud
├── docker-compose.yml         # Konfigurasi deploy kontainer lokal/cloud
├── requirements.txt           # Dependensi inti
├── requirements-cloud.txt     # Dependensi khusus Cloud (Linux CUDA)
├── requirements-local.txt     # Dependensi khusus macOS (Apple Silicon)
├── .env.example               # Template environment variable
└── start.sh                   # Runner script (mendukung mode local & cloud)
```

---

## 🚀 Cara Menjalankan

### 1. Menjalankan Secara Lokal (macOS Apple Silicon)
Gunakan environment yang disiapkan via `setup.sh`:
```bash
# Dari root repositori
./start.sh
# atau langsung dari folder backend
bash backend/start.sh
```
Layanan akan aktif pada:
- **TTS (MLX)**: `http://localhost:8808`
- **LipSync (CoreML)**: `http://localhost:8810`

### 2. Menjalankan di Docker / Cloud GPU
Pastikan driver NVIDIA dan NVIDIA Container Toolkit sudah terpasang di VM:
```bash
# Menggunakan Docker Compose
cd backend
docker-compose up -d --build
```
Atau manual via Docker:
```bash
docker build -t interviewtime-backend -f backend/Dockerfile .
docker run --gpus all -p 8808:8808 -p 8810:8810 -v $(pwd)/models:/app/models interviewtime-backend
```

### 3. Deploy ke RunPod Serverless (TTS)
Frontend Swift (`RunPodTTSClient.swift`) siap menggunakan endpoint serverless RunPod:
1. Build image dengan entrypoint `backend/tts/runpod_handler.py`.
2. Push image ke container registry (misal: Docker Hub / GHCR).
3. Buat template RunPod Serverless dan set Handler ke image Anda.
4. Masukkan **Endpoint ID** dan **API Key** ke antarmuka aplikasi.

### 4. Deploy ke Modal Cloud (TTS)
```bash
# Uji coba ephemeral
modal run backend/tts/modal_app.py --text "Halo, selamat datang di sesi wawancara."

# Deploy endpoint publik permanen
modal deploy backend/tts/modal_app.py
```

---

## 📡 API Reference

### TTS Server (Port 8808)
- `GET /health`  
  Cek kesiapan model TTS (`status: "ok"`, `engine`, `sample_rate`).
- `POST /speak`  
  Sintesis audio full WAV dari teks masukan.  
  **Body**:
  ```json
  {
    "text": "Selamat pagi, silakan perkenalkan diri Anda.",
    "emotion": "calm",
    "cfg_value": 2.5,
    "inference_timesteps": 6,
    "max_tokens": 2000,
    "warmup_patches": 2
  }
  ```
  **Response**: Audio `audio/wav` streaming.
- `POST /speak_stream`  
  Streaming raw float32 PCM audio dengan header 8-byte LE (`[sample_rate, channels]`).
- `GET /config` & `POST /config`  
  Membaca dan memperbarui parameter inferensi TTS secara runtime.

### LipSync Server (Port 8810)
- `GET /health`  
  Cek kesiapan server LipSync (`status: "ok"`).
- `POST /lipsync_stream`  
  Merender segmen video MP4 lip-synced secara bertahap (chunked streaming).  
  **Body (multipart/form-data)**:
  - `image`: File gambar wajah pewawancara (`source.png`)
  - `audio`: File WAV suara (`audio.wav`)
  - `fps`: Frame rate (default: `10` atau `25`)
  - `seg_frames`: Jumlah frame per segmen streaming (default: `10`)
  **Response**: Binary stream dengan format `[4-byte big-endian length][mp4 bytes]...[4-byte zero length (EOF)]`.

---

## 🧹 Dead Code yang Telah Dihapus
1. **SadTalker Legacy Code**: Semua referensi direktori `SadTalker`, parameter `generate_video`, `source_image`, dan fungsi `run_sadtalker` yang sudah usang telah dihapus seluruhnya dari server TTS.
2. **Duplikasi Konfigurasi**: Pembersihan variabel ganda seperti `STREAM_CFG_VALUE = 2.5` diikuti `STREAM_CFG_VALUE = 2.0`.
3. **Script Pelatihan & Upstream MuseTalk**: Script pelatihan model dari awal (`train.py`, `train.sh`), script GUI demo Gradio upstream (`app.py`), batch file Windows (`download_weights.bat`), dan testing script ad-hoc telah dihapus dari codebase production.
