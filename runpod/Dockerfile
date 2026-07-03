# VoxCPM2 TTS on RunPod Serverless.
# python:3.11-slim + pip torch (the torch wheel bundles CUDA; RunPod supplies the
# GPU driver) — same recipe that worked on Modal, no CUDA base image needed.
FROM python:3.11-slim

# torch.compile disabled: VoxCPM2's fullgraph compile hits a fatal dynamo graph
# break on einops; eager runs fine.
ENV TORCH_COMPILE_DISABLE=1 \
    TORCHDYNAMO_DISABLE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir voxcpm runpod soundfile numpy

# Bake the model into the image so cold start only loads into VRAM, no download.
RUN python -c "from huggingface_hub import snapshot_download; \
    snapshot_download('openbmb/VoxCPM2', local_dir='/models/VoxCPM2')"

COPY ref_voice.wav /assets/ref_voice.wav
COPY handler.py /handler.py

CMD ["python", "-u", "/handler.py"]
