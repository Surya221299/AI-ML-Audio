# VoxCPM2 TTS on RunPod Serverless.
# python:3.11-slim + pip torch (the torch wheel bundles CUDA; RunPod supplies the
# GPU driver) — same recipe that worked on Modal, no CUDA base image needed.
FROM python:3.11-slim

# torch.compile disabled: VoxCPM2's fullgraph compile hits a fatal dynamo graph
# break on einops; eager runs fine.
ENV TORCH_COMPILE_DISABLE=1 \
    TORCHDYNAMO_DISABLE=1 \
    PYTHONUNBUFFERED=1

# slim lacks native libs the stack dlopens at import: libsndfile1 (soundfile),
# libgomp1 (torch's OpenMP). Missing them = silent worker crash at import,
# before runpod attaches logging, so the dashboard shows nothing.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg libsndfile1 libgomp1 && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir voxcpm runpod soundfile numpy

# Fail the BUILD (where logs are visible) if any import can't load its native
# libs, instead of dying silently at runtime.
RUN python -c "import soundfile, torch, voxcpm; print('imports OK')"

# Bake the model into the image so cold start only loads into VRAM, no download.
RUN python -c "from huggingface_hub import snapshot_download; \
    snapshot_download('openbmb/VoxCPM2', local_dir='/models/VoxCPM2')"

COPY ref_voice.wav /assets/ref_voice.wav
COPY handler.py /handler.py

CMD ["python", "-u", "/handler.py"]
