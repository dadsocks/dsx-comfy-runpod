FROM nvidia/cuda:12.1.0-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=3000 \
    COMFY_DIR=/opt/ComfyUI \
    WORKDIR=/workspace

RUN apt-get update && apt-get install -y --no-install-recommends \
    git wget curl ca-certificates tini ffmpeg build-essential python3 python3-pip \
 && rm -rf /var/lib/apt/lists/*

# Optional: non-root user
RUN useradd -m -u 1000 appuser
USER appuser
WORKDIR /home/appuser

# ---- ComfyUI core ----
RUN git clone https://github.com/comfyanonymous/ComfyUI.git ${COMFY_DIR}
WORKDIR ${COMFY_DIR}
RUN pip3 install --upgrade pip && pip3 install -r requirements.txt

# ---- Must-have custom nodes ----
WORKDIR ${COMFY_DIR}/custom_nodes
RUN git clone https://github.com/ltdrdata/ComfyUI-Manager.git
RUN git clone https://github.com/city96/ComfyUI-GGUF.git
RUN git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git
RUN git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git

WORKDIR ${COMFY_DIR}/custom_nodes/ComfyUI-VideoHelperSuite
RUN pip3 install -r requirements.txt || true

WORKDIR ${COMFY_DIR}/custom_nodes/ComfyUI-WanVideoWrapper
RUN pip3 install -r requirements.txt || true

# Back to Comfy root
WORKDIR ${COMFY_DIR}

# Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
  CMD curl -f http://localhost:${PORT}/ || exit 1

# Startup script
USER root
COPY --chown=appuser:appuser start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
USER appuser

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/start.sh"]

