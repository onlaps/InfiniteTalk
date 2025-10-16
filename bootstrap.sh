#!/usr/bin/env bash
# Bootstrap InfiniteTalk on Vast.ai (Linux). Idempotent.
set -euo pipefail

# ---- config (matches your Quick Start) ----
ENV_NAME="${ENV_NAME:-multitalk}"
PYTHON_VERSION="${PYTHON_VERSION:-3.10}"
TORCH_VER="${TORCH_VER:-2.4.1}"
TV_VER="${TV_VER:-0.19.1}"
TA_VER="${TA_VER:-2.4.1}"
XFORMERS_VER="${XFORMERS_VER:-0.0.28}"
CUDA_WHL_INDEX="${CUDA_WHL_INDEX:-https://download.pytorch.org/whl/cu121}"
FLASH_ATTN_VER="${FLASH_ATTN_VER:-2.7.4.post1}"

# Persist caches/models on the Vast local volume mounted at /data
export HF_HOME="${HF_HOME:-/data/hf}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-/data/hf/hub}"
mkdir -p "$HF_HUB_CACHE"

# Model dirs (as in your doc)
WEIGHTS_DIR="${WEIGHTS_DIR:-$(pwd)/weights}"
WAN_DIR="${WAN_DIR:-${WEIGHTS_DIR}/Wan2.1-I2V-14B-480P}"
W2V2_DIR="${W2V2_DIR:-${WEIGHTS_DIR}/chinese-wav2vec2-base}"
IT_DIR="${IT_DIR:-${WEIGHTS_DIR}/InfiniteTalk}"

SKIP_WEIGHTS="${SKIP_WEIGHTS:-0}"

have() { command -v "$1" &>/dev/null; }

maybe_sudo() { command -v sudo &>/dev/null && echo sudo || true; }
SUDO="$(maybe_sudo)"

ensure_base_tools() {
  if have apt-get; then
    $SUDO apt-get update -y
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git curl ca-certificates build-essential pkg-config
  elif have yum; then
    $SUDO yum install -y git curl ca-certificates gcc gcc-c++ make pkgconfig
  fi
}

ensure_conda() {
  if have conda; then
    # shellcheck disable=SC1091
    source "$(conda info --base)/etc/profile.d/conda.sh"
  else
    echo "Installing Miniforge…"
    TMP="$(mktemp -d)"; pushd "$TMP" >/dev/null
    URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-$(uname -m).sh"
    curl -fsSL "$URL" -o miniforge.sh
    bash miniforge.sh -b -p "$HOME/miniforge3"
    # shellcheck disable=SC1091
    source "$HOME/miniforge3/etc/profile.d/conda.sh"
    conda init bash || true
    popd >/dev/null
  fi
}

create_env() {
  conda env list | grep -qE "^\s*${ENV_NAME}\s" || conda create -y -n "${ENV_NAME}" "python=${PYTHON_VERSION}"
  conda activate "${ENV_NAME}"
}

install_step1() {
  pip install --upgrade pip setuptools wheel
  pip install "torch==${TORCH_VER}" "torchvision==${TV_VER}" "torchaudio==${TA_VER}" --index-url "${CUDA_WHL_INDEX}"
  pip install -U "xformers==${XFORMERS_VER}" --index-url "${CUDA_WHL_INDEX}"
}

install_step2() {
  pip install 'misaki[en]' ninja psutil packaging wheel
  pip install "flash_attn==${FLASH_ATTN_VER}"
}

install_step3() {
  pip install -r requirements.txt
  conda install -y -c conda-forge librosa
}

install_ffmpeg() {
  conda install -y -c conda-forge ffmpeg || (have yum && $SUDO yum install -y ffmpeg ffmpeg-devel) || echo "Please install ffmpeg manually."
}

install_hf_cli() {
  # Ensure the new 'hf' CLI is installed (huggingface_hub provides it)
  pip install -U "huggingface_hub>=0.23"
  hf --help >/dev/null 2>&1 || echo "Warning: 'hf' not on PATH; relogin or source your shell rc if needed."  # new CLI; replaces huggingface-cli
}

download_models() {
  echo "Downloading models to ${WEIGHTS_DIR} (cache at ${HF_HUB_CACHE})"
  mkdir -p "${WAN_DIR}" "${W2V2_DIR}" "${IT_DIR}"
  hf download Wan-AI/Wan2.1-I2V-14B-480P --local-dir "${WAN_DIR}"
  hf download TencentGameMate/chinese-wav2vec2-base --local-dir "${W2V2_DIR}"
  hf download TencentGameMate/chinese-wav2vec2-base:model.safetensors --revision refs/pr/1 --local-dir "${W2V2_DIR}"
  hf download MeiGen-AI/InfiniteTalk --local-dir "${IT_DIR}"
}

ensure_base_tools
ensure_conda
# shellcheck disable=SC1091
source "$(conda info --base)/etc/profile.d/conda.sh"
create_env
install_step1
install_step2
install_step3
install_ffmpeg
install_hf_cli

if [[ "${SKIP_WEIGHTS}" != "1" ]]; then
  download_models
else
  echo "Skipping weights download (SKIP_WEIGHTS=1)"
fi

echo "Done. Activate with: conda activate ${ENV_NAME}"