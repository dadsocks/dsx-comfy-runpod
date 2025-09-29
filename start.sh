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
CLIPV_DIR="$MODEL_ROOT/clip_vision"
LORAS_DIR="$MODEL_ROOT/loras"

mkdir -p "$UNET_DIR" "$TXT_DIR" "$VAE_DIR" "$WAN_DIR" "$CLIPV_DIR" "$LORAS_DIR"

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

# 🔧 Flatten split_files layout into proper ComfyUI folders
flatten_split_files() {
  # Move files up from split_files/* into the right model dirs
  shopt -s nullglob

  # diffusion_models
  if compgen -G "$WAN_DIR/split_files/diffusion_models/*.safetensors" > /dev/null; then
    echo "[fixup] Flattening diffusion_models -> $(basename "$WAN_DIR")"
    mv "$WAN_DIR/split_files/diffusion_models/"*.safetensors "$WAN_DIR/" || true
    rm -rf "$WAN_DIR/split_files" || true
  fi

  # text_encoders
  if compgen -G "$TXT_DIR/split_files/text_encoders/*.safetensors" > /dev/null; then
    echo "[fixup] Flattening text_encoders -> $(basename "$TXT_DIR")"
    mv "$TXT_DIR/split_files/text_encoders/"*.safetensors "$TXT_DIR/" || true
    rm -rf "$TXT_DIR/split_files" || true
  fi

  # vae
  if compgen -G "$VAE_DIR/split_files/vae/*.safetensors" > /dev/null; then
    echo "[fixup] Flattening vae -> $(basename "$VAE_DIR")"
    mv "$VAE_DIR/split_files/vae/"*.safetensors "$VAE_DIR/" || true
    rm -rf "$VAE_DIR/split_files" || true
  fi

  # clip_vision
  if compgen -G "$CLIPV_DIR/split_files/clip_vision/*" > /dev/null; then
    echo "[fixup] Flattening clip_vision -> $(basename "$CLIPV_DIR")"
    mv "$CLIPV_DIR/split_files/clip_vision/"* "$CLIPV_DIR/" || true
    rm -rf "$CLIPV_DIR/split_files" || true
  fi
  # add .safetensors if HF saved without extension
  if [[ -f "$CLIPV_DIR/clip_vision_h" && ! -f "$CLIPV_DIR/clip_vision_h.safetensors" ]]; then
    mv "$CLIPV_DIR/clip_vision_h" "$CLIPV_DIR/clip_vision_h.safetensors" || true
  fi

  # ---- LORAs: flatten known subfolders ----
  # Lightx2v/*
  if compgen -G "$LORAS_DIR/Lightx2v/*" > /dev/null; then
    echo "[fixup] Flattening loras/Lightx2v -> loras"
    for f in "$LORAS_DIR/Lightx2v/"*; do
      base="$(basename "$f")"
      if [[ -f "$f" ]]; then
        [[ "$base" != *.safetensors ]] && mv "$f" "$LORAS_DIR/${base}.safetensors" || mv "$f" "$LORAS_DIR/$base"
      fi
    done
    rm -rf "$LORAS_DIR/Lightx2v" || true
  fi

  # LoRAs/Wan22_relight/*
  if compgen -G "$LORAS_DIR/LoRAs/Wan22_relight/*" > /dev/null; then
    echo "[fixup] Flattening loras/LoRAs/Wan22_relight -> loras"
    for f in "$LORAS_DIR/LoRAs/Wan22_relight/"*; do
      base="$(basename "$f")"
      if [[ -f "$f" ]]; then
        [[ "$base" != *.safetensors ]] && mv "$f" "$LORAS_DIR/${base}.safetensors" || mv "$f" "$LORAS_DIR/$base"
      fi
    done
    rm -rf "$LORAS_DIR/LoRAs" || true
  fi

  # Generic: move any *.safetensors from one-level subfolders of loras up
  for f in "$LORAS_DIR"/*/*.safetensors; do
    mv "$f" "$LORAS_DIR/" || true
  done
  # Add .safetensors to any lora file that somehow lacks an extension
  for f in "$LORAS_DIR"/*; do
    [[ -f "$f" && "${f##*.}" = "$f" ]] && mv "$f" "$f.safetensors" || true
  done
  # Remove empty dirs
  find "$LORAS_DIR" -mindepth 1 -type d -empty -delete || true

  # Clean caches (we redownload every boot anyway)
  rm -rf \
    "$MODEL_ROOT/.cache" \
    "$WAN_DIR/.cache" \
    "$TXT_DIR/.cache" \
    "$VAE_DIR/.cache" \
    "$CLIPV_DIR/.cache" \
    "$LORAS_DIR/.cache" || true

  shopt -u nullglob
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

: "${FLUX_VAE_REPO:=}"
: "${FLUX_VAE_FILE:=}"
: "${FLUX_TENC_REPO:=}"
: "${FLUX_TENC_FILE:=}"
download_flux_extras_if_configured() {
  if [[ -n "$FLUX_VAE_REPO" && -n "$FLUX_VAE_FILE" ]]; then
    echo "[flux] Downloading VAE ➜ $FLUX_VAE_REPO :: $FLUX_VAE_FILE"
    hf_dl "$FLUX_VAE_REPO" "$FLUX_VAE_FILE" "$VAE_DIR"
  else
    echo "[flux] VAE not set (FLUX_VAE_*)."
  fi
  if [[ -n "$FLUX_TENC_REPO" && -n "$FLUX_TENC_FILE" ]]; then
    echo "[flux] Downloading text encoder ➜ $FLUX_TENC_REPO :: $FLUX_TENC_FILE"
    hf_dl "$FLUX_TENC_REPO" "$FLUX_TENC_FILE" "$TXT_DIR"
  else
    echo "[flux] Text encoder not set (FLUX_TENC_*)."
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

# ---------------- Your workflow-specific extras ----------------
# clip_vision
: "${CLIPV_REPO:=Comfy-Org/Wan_2.1_ComfyUI_repackaged}"
: "${CLIPV_FILE:=split_files/clip_vision/clip_vision_h.safetensors}"
# WAN 2.1 VAE
: "${WAN21_VAE_REPO:=Comfy-Org/Wan_2.1_ComfyUI_repackaged}"
: "${WAN21_VAE_FILE:=split_files/vae/wan_2.1_vae.safetensors}"
# LoRAs
: "${LORA_LIGHTX2V_REPO:=Kijai/WanVideo_comfy}"
: "${LORA_LIGHTX2V_FILE:=Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors}"
: "${LORA_RELIGHT_REPO:=Kijai/WanVideo_comfy}"
: "${LORA_RELIGHT_FILE:=LoRAs/Wan22_relight/WanAnimate_relight_lora_fp16.safetensors}"

download_workflow_required_models() {
  echo "[clip_vision] $CLIPV_REPO :: $CLIPV_FILE"
  hf_dl "$CLIPV_REPO" "$CLIPV_FILE" "$CLIPV_DIR"

  echo "[vae] $WAN21_VAE_REPO :: $WAN21_VAE_FILE"
  hf_dl "$WAN21_VAE_REPO" "$WAN21_VAE_FILE" "$VAE_DIR"

  echo "[lora] $LORA_LIGHTX2V_REPO :: $LORA_LIGHTX2V_FILE"
  hf_dl "$LORA_LIGHTX2V_REPO" "$LORA_LIGHTX2V_FILE" "$LORAS_DIR"

  echo "[lora] $LORA_RELIGHT_REPO :: $LORA_RELIGHT_FILE"
  hf_dl "$LORA_RELIGHT_REPO" "$LORA_RELIGHT_FILE" "$LORAS_DIR"
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
    download_wan22_animate_comfy || echo "[wan22] skipped (download error)"
  fi
  # Your workflow-specific extras (clip_vision + VAE + LoRAs)
  download_workflow_required_models
  # 🔧 Normalize layout so ComfyUI sees the files
  flatten_split_files
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
  # run code-server with PORT unset so it won't steal 3000
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
