#!/usr/bin/env bash
# Bootstrap InfiniteTalk on Vast.ai (Linux). Idempotent & Python-3.10-forced.
set -euo pipefail

# ---------------- config ----------------
# Use a fixed conda prefix so name collisions can't shadow us.
MINIFORGE_PREFIX="${MINIFORGE_PREFIX:-/opt/miniforge3}"
ENV_PREFIX="${ENV_PREFIX:-${MINIFORGE_PREFIX}/envs/it310}"   # <- Python 3.10 lives here
PYTHON_VERSION="${PYTHON_VERSION:-3.10}"                     # FORCE 3.10

# Torch/CUDA stack
TORCH_VER="${TORCH_VER:-2.4.1}"
TV_VER="${TV_VER:-0.19.1}"
TA_VER="${TA_VER:-2.4.1}"
XFORMERS_VER="${XFORMERS_VER:-0.0.28}"
FLASH_ATTN_VER="${FLASH_ATTN_VER:-2.7.4.post1}"
CUDA_WHL_INDEX="${CUDA_WHL_INDEX:-https://download.pytorch.org/whl/cu121}"

# Project deps
REQS_FILE="${REQS_FILE:-requirements.txt}"
PIP_EAGER="${PIP_EAGER:-1}"

# HF cache on Vast volume
export HF_HOME="${HF_HOME:-/data/hf}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-/data/hf/hub}"
mkdir -p "$HF_HUB_CACHE"

# Model dirs
WEIGHTS_DIR="${WEIGHTS_DIR:-$(pwd)/weights}"
WAN_DIR="${WAN_DIR:-${WEIGHTS_DIR}/Wan2.1-I2V-14B-480P}"
W2V2_DIR="${W2V2_DIR:-${WEIGHTS_DIR}/chinese-wav2vec2-base}"
IT_DIR="${IT_DIR:-${WEIGHTS_DIR}/InfiniteTalk}"

SKIP_WEIGHTS="${SKIP_WEIGHTS:-0}"
SKIP_HF_LOGIN="${SKIP_HF_LOGIN:-0}"

have() { command -v "$1" >/dev/null 2>&1; }
maybe_sudo() { command -v sudo >/dev/null 2>&1 && echo sudo || true; }
SUDO="$(maybe_sudo)"

# ---------- harden PATH against rogue /venv -----------
# Ensure no /venv/*/bin shadows our 3.10 conda env in THIS process.
if [[ "${PATH:-}" =~ :?/venv/ ]]; then
  PATH="$(awk -v RS=: -v ORS=: '$0 !~ /^\/venv\// {print}' <<<"$PATH")"
  PATH="${PATH%:}"
  export PATH
  hash -r || true
fi
unset VIRTUAL_ENV || true
export UV_NO_AUTO_ACTIVATE=1 || true

ensure_base_tools() {
  if have apt-get; then
    $SUDO apt-get update -y
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git curl ca-certificates build-essential pkg-config
  elif have yum; then
    $SUDO yum install -y git curl ca-certificates gcc gcc-c++ make pkgconfig
  fi
}

ensure_miniforge() {
  if [[ ! -x "${MINIFORGE_PREFIX}/bin/conda" ]]; then
    echo "Installing Miniforge into ${MINIFORGE_PREFIX}…"
    TMP="$(mktemp -d)"
    arch="$(uname -m)"
    curl -fsSL "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${arch}.sh" -o "$TMP/miniforge.sh"
    bash "$TMP/miniforge.sh" -b -p "${MINIFORGE_PREFIX}"
  fi
  # shellcheck disable=SC1091
  source "${MINIFORGE_PREFIX}/etc/profile.d/conda.sh"
}

ensure_env() {
  if [[ ! -x "${ENV_PREFIX}/bin/python" ]]; then
    conda create -y -p "${ENV_PREFIX}" "python=${PYTHON_VERSION}"
  fi
  # We still 'activate' for PATH in this subshell; all critical calls use conda run anyway.
  conda activate "${ENV_PREFIX}"
}

pip_run() { conda run -p "${ENV_PREFIX}" python -m pip "$@"; }
py_run()  { conda run -p "${ENV_PREFIX}" python "$@"; }
hf_run()  { conda run -p "${ENV_PREFIX}" hf "$@"; }

install_core() {
  # heavy native via conda first (keeps builds minimal) incl. NumPy 2 for thinc/spaCy
  conda install -y -p "${ENV_PREFIX}" -c conda-forge "numpy>=2.0" ffmpeg librosa

  pip_run install --upgrade pip setuptools wheel

  # PyTorch CUDA 12.1 stack
  pip_run install "torch==${TORCH_VER}" "torchvision==${TV_VER}" "torchaudio==${TA_VER}" --index-url "${CUDA_WHL_INDEX}"

  # xformers / flash-attn matched to torch/cu121
  pip_run install -U "xformers==${XFORMERS_VER}"
  pip_run install "flash_attn==${FLASH_ATTN_VER}"

  # common libs your repo uses
  pip_run install -U diffusers>=0.29.0 transformers>=4.40.0 accelerate>=0.28.0 safetensors>=0.4.2 einops
}

install_project_reqs() {
  if [[ -f "${REQS_FILE}" ]]; then
    if [[ "${PIP_EAGER}" == "1" ]]; then
      pip_run install --upgrade --upgrade-strategy eager -r "${REQS_FILE}"
    else
      pip_run install -r "${REQS_FILE}"
    fi
  else
    echo "Note: ${REQS_FILE} not found; skipping."
  fi
}

install_hf_cli() {
  pip_run install -U "huggingface_hub>=0.23"
  if [[ "${SKIP_HF_LOGIN}" != "1" && -n "${HF_TOKEN:-}" ]]; then
    py_run - <<'PY'
from huggingface_hub import login
import os
tok=os.environ.get("HF_TOKEN","").strip()
if tok: login(tok, add_to_git_credential=True)
PY
  fi
}

download_models() {
  echo "Downloading models to ${WEIGHTS_DIR} (cache at ${HF_HUB_CACHE})"
  mkdir -p "${WAN_DIR}" "${W2V2_DIR}" "${IT_DIR}"

  # Whole repos
  hf_run download Wan-AI/Wan2.1-I2V-14B-480P --local-dir "${WAN_DIR}"
  hf_run download TencentGameMate/chinese-wav2vec2-base --local-dir "${W2V2_DIR}"

  # Single file from PR revision (correct syntax: --include + --revision)
  hf_run download TencentGameMate/chinese-wav2vec2-base \
    --include "model.safetensors" \
    --revision "refs/pr/1" \
    --local-dir "${W2V2_DIR}"

  hf_run download MeiGen-AI/InfiniteTalk --local-dir "${IT_DIR}"
}

main() {
  ensure_base_tools
  ensure_miniforge
  ensure_env
  install_core
  install_project_reqs
  install_hf_cli

  if [[ "${SKIP_WEIGHTS}" != "1" ]]; then
    download_models
  else
    echo "Skipping weights download (SKIP_WEIGHTS=1)"
  fi

  echo
  echo "✅ Done."
  echo "Use this interpreter explicitly to avoid PATH issues:"
  echo "  ${ENV_PREFIX}/bin/python -V"
  echo "Activate in a new shell with:"
  echo "  source ${MINIFORGE_PREFIX}/etc/profile.d/conda.sh && conda activate ${ENV_PREFIX}"
}
main "$@"