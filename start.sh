#!/bin/zsh
# Start both servers: MLX TTS on :8808 and MuseTalk lip-sync on :8810

set -e
cd "$(dirname "$0")"

echo "==> Starting MLX TTS server (:8808)..."
envs/voxcpm-env/bin/python server_mlx.py &
MLX_PID=$!

echo "==> Starting MuseTalk lip-sync server (:8810)..."
envs/musetalk-env/bin/python MuseTalk/musetalk_server.py &
MUSE_PID=$!

trap "kill $MLX_PID $MUSE_PID 2>/dev/null" INT TERM

echo ""
echo "Both servers running. Press Ctrl+C to stop."
wait
