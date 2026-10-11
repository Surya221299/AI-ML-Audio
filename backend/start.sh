#!/bin/bash
# Start backend servers: TTS (:8808) and LipSync (:8810)
# Supports both Local (Apple Silicon) and Cloud (CUDA / Docker) modes.

set -e

BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$BACKEND_DIR/.." && pwd)"

export PYTHONPATH="$ROOT_DIR:$PYTHONPATH"

# Check if running in cloud container or local macOS
if [ "$1" == "--cloud" ] || [ -f "/.dockerenv" ]; then
    echo "==> [Cloud Mode] Starting TTS CUDA server (:8808)..."
    python -m backend.tts.server_cuda &
    TTS_PID=$!

    echo "==> [Cloud Mode] Starting LipSync PyTorch server (:8810)..."
    python -m backend.lipsync.server &
    LIP_PID=$!
else
    echo "==> [Local Mode] Starting MLX TTS server (:8808)..."
    "$ROOT_DIR/envs/voxcpm-env/bin/python" -m backend.tts.server_mlx &
    TTS_PID=$!

    echo "==> [Local Mode] Starting MuseTalk LipSync server (:8810)..."
    "$ROOT_DIR/envs/musetalk-env/bin/python" -m backend.lipsync.server &
    LIP_PID=$!
fi

trap "kill $TTS_PID $LIP_PID 2>/dev/null" INT TERM

echo ""
echo "✓ Both backend servers running."
echo "  - TTS:     http://localhost:8808"
echo "  - LipSync: http://localhost:8810"
echo "Press Ctrl+C to stop."
wait
