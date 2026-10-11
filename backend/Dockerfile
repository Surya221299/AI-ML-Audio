# Multi-stage / Production GPU Dockerfile for AI-ML-Audio Backend
FROM pytorch/pytorch:2.2.1-cuda12.1-cudnn8-runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Install system dependencies (ffmpeg is essential for audio & video muxing)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    libsndfile1 \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python requirements
COPY requirements.txt requirements-cloud.txt ./backend/
RUN pip install --no-cache-dir -r ./backend/requirements-cloud.txt

# Copy backend code
COPY . /app/backend/

# Set Python module search path
ENV PYTHONPATH=/app

# Expose TTS (:8808) and LipSync (:8810) ports
EXPOSE 8808 8810

# Default command starts both TTS and LipSync servers
CMD ["bash", "/app/backend/start.sh", "--cloud"]
