#!/usr/bin/env bash
set -euo pipefail

export COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
export WORKDIR="${WORKDIR:-/workspace}"
export PORT="${PORT:-3000}"

mkdir -p "$WORKDIR/models/unet" \
         "$WORKDIR/models/diffusion_models" \
         "$WORKDIR/models/text_encoders" \
         "$WORKDIR/models/vae" \
         "$WORKDIR/input" "$WORKDIR/output" "$WORKDIR/temp"

mkdir -p "$COMFY_DIR/models"
rm -f "$COMFY_DIR/models"/* 2>/dev/null || true
ln -sf "$WORKDIR/models" "$COMFY_DIR/models"

cd "$COMFY_DIR"
echo "ComfyUI on ${PORT}; models at ${WORKDIR}/models"
python3 main.py --listen 0.0.0.0 --port "${PORT}"

