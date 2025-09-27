#!/usr/bin/env bash
set -euo pipefail

# -------- Paths & ports --------
export COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
export PORT="${PORT:-3000}"

# -------- Model choices via ENV VARS (override in RunPod Template) --------
: "${FLUX_REPO:=black-forest-labs/FLUX.1-dev-gguf}"
: "${FLUX_FILE:=flux1-dev.gguf}"

: "${QWEN_REPO:=QuantStack/Qwen-Image-Edit-2509-GGUF}"
: "${QWEN_UNET_FILE:=Qwen-Image-Edit-2509.gguf}"
: "${QWEN_TXT_FILE:=Qwen2.5-VL-7B.Q8_0.gguf}"
: "${QWEN_VAE_FILE:=Qwen-Image-Edit-2509.vae.safetensors}"

: "${WAN_REPO:=Kijai/WanVideo_comfy}"
: "${WAN_FILE:=wan-2.2-animate.safetensors}"

# If true, wipe models each boot (ensures fresh downloads)
: "${CLEAN_MODELS_ON_BOOT:=true}"

# -------- Prepare ComfyUI model folders (inside the container) --------
MODEL_ROOT="$COMFY_DIR/models"
UNET_DIR="$MODEL_ROOT/unet"
TXT_DIR="$MODEL_ROOT/text_encoders"
VAE_DIR="$MODEL_ROOT/vae"
WAN_DIR="$MODEL_ROOT/diffusion_models"

mkdir -p "$UNET_DIR" "$TXT_DIR" "$VAE_DIR" "$WAN_DIR"

if [[ "${CLEAN_MODELS_ON_BOOT}" == "true" ]]; then
  echo "[boot] Cleaning previous models in $MODEL_ROOT ..."
  rm -rf "${UNET_DIR:?}/"* "${TXT_DIR:?}/"* "${VAE_DIR:?}/"* "${WAN_DIR:?}/"*
fi

# -------- Download models on every start --------
if [[ -z "${HF_TOKEN:-}" ]]; then
  echo "[boot] HF_TOKEN not set. Set it in your RunPod template to enable auto-downloads."
else
  echo "[boot] Installing huggingface_hub ..."
  pip3 install --quiet --upgrade huggingface_hub

  echo "[boot] Downloading FLUX ➜ $FLUX_REPO :: $FLUX_FILE"
  huggingface-cli download --token "$HF_TOKEN" "$FLUX_REPO" "$FLUX_FILE" \
    --local-dir "$UNET_DIR" --local-dir-use-symlinks False

  echo "[boot] Downloading Qwen-Image-Edit-2509 components ..."
  huggingface-cli download --token "$HF_TOKEN" "$QWEN_REPO" "$QWEN_UNET_FILE" \
    --local-dir "$UNET_DIR" --local-dir-use-symlinks False
  huggingface-cli download --token "$HF_TOKEN" "$QWEN_REPO" "$QWEN_TXT_FILE" \
    --local-dir "$TXT_DIR" --local-dir-use-symlinks False
  huggingface-cli download --token "$HF_TOKEN" "$QWEN_REPO" "$QWEN_VAE_FILE" \
    --local-dir "$VAE_DIR" --local-dir-use-symlinks False

  echo "[boot] Downloading WAN 2.2 Animate ➜ $WAN_REPO :: $WAN_FILE"
  huggingface-cli download --token "$HF_TOKEN" "$WAN_REPO" "$WAN_FILE" \
    --local-dir "$WAN_DIR" --local-dir-use-symlinks False
fi

# -------- Start ComfyUI --------
echo "====================================================="
echo "ComfyUI starting on port ${PORT}"
echo "Models directory: ${MODEL_ROOT}  (ephemeral; refreshed each boot)"
echo "====================================================="

cd "$COMFY_DIR"
python3 main.py --listen 0.0.0.0 --port "${PORT}"
