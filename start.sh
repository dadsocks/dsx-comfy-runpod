#!/usr/bin/env bash
set -euo pipefail

# -------- Paths & ports --------
export COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
export PORT="${PORT:-3000}"

# -------- Model choices via ENV VARS (override in RunPod Template) --------
: "${FLUX_REPO:=black-forest-labs/FLUX.1-dev-gguf}"
: "${FLUX_FILE:=flux1-dev.gguf}"

# Qwen precision toggle (native Comfy-Org packs): fp8 (default) or bf16
: "${QWEN_EDIT_PRECISION:=fp8}"

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
  # (hf_transfer speeds up downloads; harmless if already present)
  pip3 install --quiet --upgrade huggingface_hub hf_transfer
  export HF_HUB_ENABLE_HF_TRANSFER=1

  # ---- FLUX (optional) ----
  echo "[boot] Downloading FLUX ➜ $FLUX_REPO :: $FLUX_FILE"
  huggingface-cli download --token "$HF_TOKEN" "$FLUX_REPO" "$FLUX_FILE" \
    --local-dir "$UNET_DIR" --local-dir-use-symlinks False

  # ---- Qwen-Image-Edit 2509 (native Comfy-Org packs) ----
  # Diffusion (pick file by precision)
  QWEN_EDIT_REPO="Comfy-Org/Qwen-Image-Edit_ComfyUI"
  if [[ "$QWEN_EDIT_PRECISION" == "bf16" ]]; then
    QWEN_EDIT_FILE="split_files/diffusion_models/qwen_image_edit_2509_bf16.safetensors"
  else
    QWEN_EDIT_FILE="split_files/diffusion_models/qwen_image_edit_2509_fp8_e4m3fn.safetensors"
  fi

  echo "[boot] Downloading Qwen-Image-Edit 2509 ($QWEN_EDIT_PRECISION)…"
  huggingface-cli download --token "$HF_TOKEN" "$QWEN_EDIT_REPO" "$QWEN_EDIT_FILE" \
    --local-dir "$WAN_DIR" --local-dir-use-symlinks False

  # Text encoder + VAE from the companion pack
  QWEN_IMG_REPO="Comfy-Org/Qwen-Image_ComfyUI"

  echo "[boot] Downloading Qwen text encoder (fp8_scaled)…"
  huggingface-cli download --token "$HF_TOKEN" "$QWEN_IMG_REPO" \
    "split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors" \
    --local-dir "$TXT_DIR" --local-dir-use-symlinks False

  echo "[boot] Downloading Qwen VAE…"
  huggingface-cli download --token "$HF_TOKEN" "$QWEN_IMG_REPO" \
    "split_files/vae/qwen_image_vae.safetensors" \
    --local-dir "$VAE_DIR" --local-dir-use-symlinks False

  # ---- WAN 2.2 Animate (optional) ----
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
