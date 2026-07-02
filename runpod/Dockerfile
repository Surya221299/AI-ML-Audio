# VoxCPM2 TTS on RunPod Serverless (CUDA GPU).
FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

# torch.compile disabled: VoxCPM2's fullgraph compile hits a fatal dynamo graph
# break on einops; eager runs fine (and T4-class GPUs can't compile bf16 anyway).
ENV TORCH_COMPILE_DISABLE=1 \
    TORCHDYNAMO_DISABLE=1 \
    PYTHONUNBUFFERED=1 \
    HF_HUB_ENABLE_HF_TRANSFER=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.11 python3-pip ffmpeg git && \
    ln -sf /usr/bin/python3.11 /usr/bin/python && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir voxcpm runpod soundfile numpy hf_transfer

# Bake the model into the image so cold start only loads into VRAM, no download.
RUN python -c "from huggingface_hub import snapshot_download; \
    snapshot_download('openbmb/VoxCPM2', local_dir='/models/VoxCPM2')"

COPY ref_voice.wav /assets/ref_voice.wav
COPY handler.py /handler.py

CMD ["python", "-u", "/handler.py"]
