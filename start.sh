#!/bin/bash
# Start both backend servers: MLX TTS (:8808) and MuseTalk LipSync (:8810)
# Delegated to backend/start.sh

cd "$(dirname "$0")"
exec bash backend/start.sh "$@"
