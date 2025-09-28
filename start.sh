#!/usr/bin/env bash
set -euo pipefail

# ---------------- Paths & ports ----------------
export COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
export PORT="${PORT:-3000}"

# Optional: faster HF downloads
export HF_HUB_ENABLE_HF_TRANSFER=1

# ---------------- Optional self-update (ComfyUI & nodes) ----------------
if [[ -n "${COMFY_SELF_UPDATE:-}" ]]; then
  echo "[self-update] Updating ComfyUI..."
  (
    cd "$COMFY_DIR"
    git reset --hard HEAD || true
    git pull --rebase --autostash || git pull --ff-only || true
    pip3 install --quiet -r requirements.txt || true
  )
  if [[ -n "${COMFY_NODES_SELF_UPDATE:-}" ]]; then
    echo "[self-update] Updating custom_nodes..."
    for repo in "ComfyUI-Manager" "ComfyUI-GGUF" "ComfyUI-VideoHelperSuite" "ComfyUI-WanVideoWrapper"; do
      [[ -d "$COMFY_DIR/custom_nodes/$repo/.git" ]] && (cd "$COMFY_DIR/custom_nodes/$repo" && git pull --rebase --autostash || git pull --ff-only || true)
    done
  fi
fi

# ---------------- Model dirs (ephemeral) ----------------
MODEL_ROOT="$COMFY_DIR/models"
UNET_DIR="$MODEL_ROOT/unet"
TXT_DIR="$MODEL_ROOT/text_encoders"
VAE_DIR="$MODEL_ROOT/vae"
WAN_DIR="$MODEL_ROOT/diffusion_models"

mkdir -p "$UNET_DIR" "$TXT_DIR" "$VAE_DIR" "$WAN_DIR"

# Stateless: wipe models each boot
: "${CLEAN_MODELS_ON_BOOT:=true}"
if [[ "${CLEAN_MODELS_ON_BOOT}" == "true" ]]; then
  echo "[boot] Cleaning previous models in $MODEL_ROOT ..."
  rm -rf "${UNET_DIR:?}/"* "${TXT_DIR:?}/"* "${VAE_DIR:?}/"* "${WAN_DIR:?}/"*
fi

# ---------------- Helpers ----------------
ensure_hf_cli() {
  # Need >=0.23 for `hf` CLI; hf_transfer speeds up downloads
  pip3 install --quiet --upgrade "huggingface_hub>=0.23" hf_transfer
  export HF_HUB_ENABLE_HF_TRANSFER=1
}

hf_dl() {
  local repo="$1"; local path="$2"; local dest="$3"
  local cmd="hf"
  command -v hf >/dev/null 2>&1 || cmd="huggingface-cli"  # fallback
  if [[ -n "${HF_TOKEN:-}" ]]; then
    "$cmd" download "$repo" "$path" --token "$HF_TOKEN" --local-dir "$dest"
  else
    "$cmd" download "$repo" "$path" --local-dir "$dest"
  fi
}

# ---------------- Qwen-Image-Edit 2509 (Comfy-Org native packs) ----------------
: "${QWEN_EDIT_PRECISION:=fp8}"  # fp8 (default) or bf16
download_qwen_image_edit_2509_native() {
  local edit_repo="Comfy-Org/Qwen-Image-Edit_ComfyUI"
  local img_repo="Comfy-Org/Qwen-Image_ComfyUI"
  local edit_file="split_files/diffusion_models/qwen_image_edit_2509_fp8_e4m3fn.safetensors"
  [[ "$QWEN_EDIT_PRECISION" == "bf16" ]] && edit_file="split_files/diffusion_models/qwen_image_edit_2509_bf16.safetensors"

  echo "[qwen] Downloading Qwen-Image-Edit 2509 ($QWEN_EDIT_PRECISION)…"
  hf_dl "$edit_repo" "$edit_file" "$WAN_DIR"

  echo "[qwen] Downloading Qwen text encoder (fp8_scaled)…"
  hf_dl "$img_repo" "split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors" "$TXT_DIR"

  echo "[qwen] Downloading Qwen VAE…"
  hf_dl "$img_repo" "split_files/vae/qwen_image_vae.safetensors" "$VAE_DIR"
}

# ---------------- WAN 2.2 Animate (Comfy-Org one-click) ----------------
# If WAN_REPO & WAN_FILE are set, we'll use those as a manual override instead.
download_wan22_animate_comfy() {
  local repo="Comfy-Org/Wan_2.2_ComfyUI_Repackaged"

  echo "[wan22] Downloading WAN 2.2 Animate 14B (BF16)…"
  hf_dl "$repo" "split_files/diffusion_models/wan2.2_animate_14B_bf16.safetensors" "$WAN_DIR"

  echo "[wan22] Downloading UMT5-XXL text encoder (recommended)…"
  hf_dl "$repo" "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" "$TXT_DIR"

  echo "[wan22] Downloading WAN 2.2 VAE…"
  hf_dl "$repo" "split_files/vae/wan2.2_vae.safetensors" "$VAE_DIR"
}

# ---------------- FLUX (optional; set FLUX_FILE to enable) ----------------
: "${FLUX_REPO:=black-forest-labs/FLUX.1-dev-gguf}"
: "${FLUX_FILE:=}"   # e.g. flux1-dev.gguf  (leave blank to skip)
download_flux_if_configured() {
  if [[ -n "$FLUX_FILE" ]]; then
    echo "[flux] Downloading $FLUX_REPO :: $FLUX_FILE"
    hf_dl "$FLUX_REPO" "$FLUX_FILE" "$UNET_DIR"
  else
    echo "[flux] Skipping (FLUX_FILE not set)."
  fi
}

# ---------------- Manual WAN override (optional) ----------------
: "${WAN_REPO:=}"    # leave empty to use Comfy-Org pack
: "${WAN_FILE:=}"    # set both WAN_REPO and WAN_FILE to override
download_wan_if_configured() {
  if [[ -n "$WAN_REPO" && -n "$WAN_FILE" ]]; then
    echo "[wan] Manual override ➜ $WAN_REPO :: $WAN_FILE"
    hf_dl "$WAN_REPO" "$WAN_FILE" "$WAN_DIR"
    return 0
  fi
  return 1
}

# ---------------- Model downloads ----------------
if [[ -z "${HF_TOKEN:-}" ]]; then
  echo "[boot] HF_TOKEN not set. Skipping model auto-downloads."
else
  echo "[boot] Installing HF tooling..."
  ensure_hf_cli

  download_qwen_image_edit_2509_native
  download_flux_if_configured

  # Try manual WAN override first; if not set, pull Comfy-Org one-click
  if ! download_wan_if_configured; then
    download_wan22_animate_comfy
  fi
fi

# ---------------- VS Code (code-server only) ----------------
# Enable with CODE_SERVER=1. Set CODE_SERVER_PASSWORD for auth (recommended).
: "${CODE_SERVER_PORT:=8080}"
if [[ -n "${CODE_SERVER:-}" ]]; then
  echo "[code-server] Starting on :${CODE_SERVER_PORT}"
  AUTH_FLAG="--auth none"
  if [[ -n "${CODE_SERVER_PASSWORD:-}" ]]; then
    export PASSWORD="$CODE_SERVER_PASSWORD"
    AUTH_FLAG="--auth password"
  fi
  command -v code-server >/dev/null 2>&1 || { echo "[code-server] not found in PATH"; exit 1; }
  # ✨ run code-server with PORT unset so it won't steal 3000
  ( env -u PORT code-server "$COMFY_DIR" --bind-addr "0.0.0.0:${CODE_SERVER_PORT}" $AUTH_FLAG ) &
  CODE_PID=$!
else
  CODE_PID=""
fi

# ---------------- Start ComfyUI (foreground) ----------------
echo "====================================================="
echo "ComfyUI : ${PORT}"
[[ -n "${CODE_SERVER:-}" ]] && echo "VS Code : ${CODE_SERVER_PORT}"
echo "Models  : ${MODEL_ROOT}  (ephemeral; re-downloaded each boot)"
echo "====================================================="

cd "$COMFY_DIR"
python3 main.py --listen 0.0.0.0 --port "${PORT}"
