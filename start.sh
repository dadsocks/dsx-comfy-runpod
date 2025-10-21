#!/usr/bin/env bash
set -euo pipefail
# Normalize HF token env name (supports HF_TOKEN)
if [[ -z "${HUGGINGFACE_HUB_TOKEN:-}" && -n "${HF_TOKEN:-}" ]]; then
  export HUGGINGFACE_HUB_TOKEN="${HF_TOKEN}"
  echo "[start] Using HF token from HF_TOKEN"
fi

# --------- Config ---------
: "${COMFY_DIR:=/opt/ComfyUI}"
: "${PORT:=3000}"
: "${HF_HOME:=/opt/hf}"
: "${HUGGINGFACE_HUB_CACHE:=/opt/hf/cache}"
: "${HF_HUB_ENABLE_HF_TRANSFER:=1}"

# Default repos & filenames (override via env if needed)
: "${FLUX_REPO:=black-forest-labs/FLUX.1-dev}"
: "${CLIP_REPO:=${FLUX_REPO}}"
: "${T5_REPO:=${FLUX_REPO}}"

: "${AE_FILE:=ae.safetensors}"
: "${CLIP_L_FILE:=clip_l.safetensors}"
: "${T5_FILE:=t5xxl_fp8_e4m3fn.safetensors}"

# Optional direct URLs (skip HF if provided)
: "${AE_URL:=}"
: "${CLIP_L_URL:=}"
: "${T5XXL_URL:=}"

# Optional extra flags to pass to ComfyUI
: "${COMFY_FLAGS:=}"

# --------- Paths ---------
VAE_DIR="${COMFY_DIR}/models/vae"
CLIP_DIR="${COMFY_DIR}/models/clip"
TXTENC_DIR="${COMFY_DIR}/models/text_encoders"

mkdir -p "${VAE_DIR}" "${CLIP_DIR}" "${TXTENC_DIR}" "${HUGGINGFACE_HUB_CACHE}" "${HF_HOME}"

echo "[start] COMFY_DIR=${COMFY_DIR}"
echo "[start] HF cache: ${HUGGINGFACE_HUB_CACHE}"
if [[ -n "${HUGGINGFACE_HUB_TOKEN:-}" ]]; then
  echo "[start] Hugging Face token detected (will use for gated assets)."
else
  echo "[start] WARNING: No HUGGINGFACE_HUB_TOKEN set. Gated files may fail to download."
fi

# --------- Ensure python deps are present ---------
python3 - <<'PY'
import sys, subprocess
def ensure(pkgs):
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--no-cache-dir", *pkgs])
try:
    import huggingface_hub  # noqa: F401
except Exception:
    ensure(["huggingface_hub", "hf-transfer"])
PY

# --------- Helper: URL download with retries ---------
download_if_missing_url () {
  local url="$1"; local dest="$2"; local name
  name="$(basename "$dest")"
  if [[ -f "$dest" ]]; then
    echo "[models] Exists: $name"
    return 0
  fi
  if [[ -z "$url" ]]; then
    return 1
  fi
  echo "[models] Fetch (URL) -> $name"
  curl -fL --retry 5 --retry-delay 2 -o "$dest" "$url"
  echo "[models] OK (URL): $name"
  return 0
}

# --------- Try explicit URLs first (if provided) ---------
download_if_missing_url "${AE_URL}"     "${VAE_DIR}/${AE_FILE}"     || true
download_if_missing_url "${CLIP_L_URL}" "${CLIP_DIR}/${CLIP_L_FILE}" || true
download_if_missing_url "${T5XXL_URL}"  "${TXTENC_DIR}/${T5_FILE}"   || true

# --------- HF fallback for anything still missing ---------
python3 - <<'PY'
import os
from huggingface_hub import hf_hub_download

COMFY = os.environ.get("COMFY_DIR","/opt/ComfyUI")

targets = [
    (os.environ.get("FLUX_REPO","black-forest-labs/FLUX.1-dev"),
     os.environ.get("AE_FILE","ae.safetensors"),
     os.path.join(COMFY,"models","vae")),
    (os.environ.get("CLIP_REPO",os.environ.get("FLUX_REPO","black-forest-labs/FLUX.1-dev")),
     os.environ.get("CLIP_L_FILE","clip_l.safetensors"),
     os.path.join(COMFY,"models","clip")),
    (os.environ.get("T5_REPO",os.environ.get("FLUX_REPO","black-forest-labs/FLUX.1-dev")),
     os.environ.get("T5_FILE","t5xxl_fp8_e4m3fn.safetensors"),
     os.path.join(COMFY,"models","text_encoders")),
]

for repo, fname, outdir in targets:
    dest = os.path.join(outdir, fname)
    os.makedirs(outdir, exist_ok=True)
    if os.path.isfile(dest):
        print(f"[models] Exists: {dest}")
        continue
    try:
        print(f"[models] Fetch (HF) {fname} from {repo} …")
        p = hf_hub_download(repo_id=repo, filename=fname,
                            local_dir=outdir, local_dir_use_symlinks=False)
        print(f"[models] OK (HF): {p}")
    except Exception as e:
        print(f"[models] FAILED (HF): {fname} from {repo} -> {e}")
PY

# --------- Print final presence ---------
for f in \
  "${VAE_DIR}/${AE_FILE}" \
  "${CLIP_DIR}/${CLIP_L_FILE}" \
  "${TXTENC_DIR}/${T5_FILE}"
do
  if [[ -f "$f" ]]; then
    echo "[models] Ready: $f"
  else
    echo "[models] MISSING: $f"
  fi
done

# --------- Launch ComfyUI ---------
cd "${COMFY_DIR}"

echo "[start] Starting ComfyUI on 0.0.0.0:${PORT}"
# shellcheck disable=SC2086
exec python3 main.py --listen 0.0.0.0 --port "${PORT}" ${COMFY_FLAGS}
