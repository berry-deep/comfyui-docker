# =============================================================================
#  ComfyUI · Docker image for Clore.ai
#  Base image : cloreai/jupyter:ubuntu24.04-v2
#
#  DESIGN NOTES
#  ------------
#  * ENTRYPOINT / CMD are intentionally NOT declared, so the base image keeps
#    its own SSH + Jupyter background services untouched.
#  * PATH is intentionally NOT modified either (the base image's boot scripts
#    may rely on their own interpreter). Always call /opt/venv/bin/python.
#  * Every heavy step is an isolated layer: the build cache stays effective and
#    no single layer exceeds ~10 GB.
#  * The PyTorch stack is pinned + constrained so that `pip install -r
#    requirements.txt` can never silently replace the CUDA 12.8 build with a
#    different one coming from PyPI.
# =============================================================================

FROM cloreai/jupyter:ubuntu24.04-v2

LABEL org.opencontainers.image.title="ComfyUI" \
      org.opencontainers.image.description="ComfyUI + ComfyUI-Manager on top of the cloreai jupyter base image" \
      org.opencontainers.image.source="https://github.com/Comfy-Org/ComfyUI"

# Never let apt ask a question (it would hang the build).
ENV DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
#  Build arguments (override with --build-arg)
# -----------------------------------------------------------------------------
ARG PYTHON_VERSION=3.12
ARG PYTORCH_VERSION=2.9.1
ARG TORCHVISION_VERSION=0.24.1
ARG TORCHAUDIO_VERSION=2.9.1
ARG CUDA_VERSION=cu128
ARG COMFYUI_REF=master

# -----------------------------------------------------------------------------
#  1) System dependencies
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        git \
        python3-venv \
        python3-dev \
        ffmpeg \
        libgl1 \
        libglib2.0-0 \
        build-essential \
    ; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
#  2) Virtualenv + PyTorch (own layer -> cacheable, keeps this layer < 10 GB)
# -----------------------------------------------------------------------------
RUN set -eux; \
    PY_BIN="/usr/bin/python${PYTHON_VERSION}"; \
    if [ ! -x "${PY_BIN}" ]; then PY_BIN="$(command -v python3)"; fi; \
    echo ">> interpreter: ${PY_BIN} ($("${PY_BIN}" -V 2>&1))"; \
    "${PY_BIN}" -m venv /opt/venv; \
    /opt/venv/bin/python -V; \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel; \
    /opt/venv/bin/pip install --no-cache-dir \
        --index-url "https://download.pytorch.org/whl/${CUDA_VERSION}" \
        "torch==${PYTORCH_VERSION}" \
        "torchvision==${TORCHVISION_VERSION}" \
        "torchaudio==${TORCHAUDIO_VERSION}"; \
    printf 'torch==%s\ntorchvision==%s\ntorchaudio==%s\n' \
        "${PYTORCH_VERSION}" "${TORCHVISION_VERSION}" "${TORCHAUDIO_VERSION}" \
        > /opt/pip-constraints.txt; \
    rm -rf /root/.cache/pip /tmp/*

# -----------------------------------------------------------------------------
#  3) ComfyUI  (COMFYUI_REF accepts a branch, a tag or a commit SHA)
# -----------------------------------------------------------------------------
RUN set -eux; \
    git clone https://github.com/Comfy-Org/ComfyUI.git /opt/ComfyUI; \
    cd /opt/ComfyUI; \
    git fetch --tags --force origin '+refs/heads/*:refs/remotes/origin/*'; \
    if ! git checkout --force "${COMFYUI_REF}"; then \
        git fetch --depth 1 origin "${COMFYUI_REF}"; \
        git checkout --force FETCH_HEAD; \
    fi; \
    git rev-parse HEAD > /opt/ComfyUI/.comfyui_commit; \
    git log -1 --pretty='%h %ci %s' > /opt/ComfyUI/.comfyui_commit_info; \
    /opt/venv/bin/pip install --no-cache-dir \
        -c /opt/pip-constraints.txt \
        -r requirements.txt; \
    rm -rf /root/.cache/pip

# -----------------------------------------------------------------------------
#  4) ComfyUI-Manager
# -----------------------------------------------------------------------------
RUN set -eux; \
    git clone https://github.com/Comfy-Org/ComfyUI-Manager.git \
        /opt/ComfyUI/custom_nodes/ComfyUI-Manager; \
    cd /opt/ComfyUI/custom_nodes/ComfyUI-Manager; \
    git rev-parse HEAD > .comfyui_manager_commit; \
    /opt/venv/bin/pip install --no-cache-dir \
        -c /opt/pip-constraints.txt \
        -r requirements.txt; \
    rm -rf /root/.cache/pip

# -----------------------------------------------------------------------------
#  5) Build-time smoke test
#     The build host has no GPU: only the import and the version strings are
#     verified here, `.cuda()` is never called.
# -----------------------------------------------------------------------------
RUN /opt/venv/bin/python -c "import torch, torchvision; print('PyTorch:', torch.__version__, 'CUDA:', torch.version.cuda)"
