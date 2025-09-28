# 1) Base image
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

# Use bash for stricter RUNs
SHELL ["/bin/bash", "-lc"]

# Basic env
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# 2) APT install (with retries)
RUN set -euxo pipefail; \
    echo 'APT::Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries; \
    apt-get update || apt-get update --allow-releaseinfo-change; \
    apt-get install -y --no-install-recommends \
        git curl ca-certificates tini ffmpeg build-essential python3 python3-pip; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

# 2.5) ✅ Install VS Code (code-server)
# Puts `code-server` in PATH (/usr/bin/code-server)
RUN curl -fsSL https://code-server.dev/install.sh | sh

# 3) Set Comfy path and selectable ref
ARG COMFY_REF=refs/heads/master   # you can override with a tag or commit SHA at build time
ENV COMFY_DIR=/opt/ComfyUI

# 4) ✅ Robust ComfyUI fetch (place this block right after APT install)
RUN set -euxo pipefail; \
    mkdir -p "${COMFY_DIR}"; \
    echo "[clone] Trying git clone…"; \
    if git clone --depth=1 --branch "${COMFY_REF##*/}" https://github.com/comfyanonymous/ComfyUI.git "${COMFY_DIR}" 2>/tmp/git.err; then \
      echo "[clone] git clone OK"; \
    else \
      echo "[clone] git clone failed. Fallback to codeload tarball:"; \
      cat /tmp/git.err || true; \
      rm -rf "${COMFY_DIR:?}/"*; \
      curl -fL --retry 5 --retry-delay 2 \
        "https://codeload.github.com/comfyanonymous/ComfyUI/tar.gz/${COMFY_REF}" \
        | tar -xz --strip-components=1 -C "${COMFY_DIR}"; \
      echo "[clone] tarball fallback OK"; \
    fi

# 5) Install ComfyUI Python deps
WORKDIR ${COMFY_DIR}
RUN pip3 install --upgrade pip && pip3 install -r requirements.txt

# ✅ Ensure CUDA 12.4 GPU Torch wheels are installed
RUN pip3 install --no-cache-dir --upgrade \
    torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu124

# 6) Custom nodes
WORKDIR ${COMFY_DIR}/custom_nodes
RUN git clone https://github.com/ltdrdata/ComfyUI-Manager.git
RUN git clone https://github.com/city96/ComfyUI-GGUF.git
RUN git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git
RUN git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git

# (Some node packs have their own deps; ignore failures if none provided)
RUN set -eux; \
    if [[ -f ${COMFY_DIR}/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt ]]; then \
      pip3 install -r ${COMFY_DIR}/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt || true; \
    fi; \
    if [[ -f ${COMFY_DIR}/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt ]]; then \
      pip3 install -r ${COMFY_DIR}/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt || true; \
    fi

# 7) Startup script and entrypoint
WORKDIR ${COMFY_DIR}
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
  CMD curl -f http://localhost:${PORT:-3000}/ || exit 1

ENTRYPOINT ["/usr/bin/tini","-s","--"]
CMD ["/usr/local/bin/start.sh"]
