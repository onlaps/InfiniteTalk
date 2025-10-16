#!/usr/bin/env bash
# Bootstrap InfiniteTalk exactly per Quick Start on a Vast.ai Linux instance.
# - Creates conda env "multitalk" (python=3.10)
# - Installs torch/cu121, xformers, flash-attn and other deps
# - Installs ffmpeg via conda-forge (fallback: yum if available)
# - Optionally downloads models via huggingface-cli into ./weights/*
# Idempotent: safe to re-run.

set -euo pipefail

# ---------------- config (matches your Quick Start) ----------------
ENV_NAME="${ENV_NAME:-multitalk}"
PYTHON_VERSION="${PYTHON_VERSION:-3.10}"

TORCH_VER="${TORCH_VER:-2.4.1}"
TV_VER="${TV_VER:-0.19.1}"
TA_VER="${TA_VER:-2.4.1}"
XFORMERS_VER="${XFORMERS_VER:-0.0.28}"
CUDA_WHL_INDEX="${CUDA_WHL_INDEX:-https://download.pytorch.org/whl/cu121}"

FLASH_ATTN_VER="${FLASH_ATTN_VER:-2.7.4.post1}"

# Model directories (exactly as in the doc)
WEIGHTS_DIR="${WEIGHTS_DIR:-$(pwd)/weights}"
WAN_DIR="${WAN_DIR:-${WEIGHTS_DIR}/Wan2.1-I2V-14B-480P}"
W2V2_DIR="${W2V2_DIR:-${WEIGHTS_DIR}/chinese-wav2vec2-base}"
IT_DIR="${IT_DIR:-${WEIGHTS_DIR}/InfiniteTalk}"

# Optional Hugging Face token (set HF_TOKEN=... env var for gated/private repos)
HF_TOKEN="${HF_TOKEN:-}"

# Skip downloading weights if set to 1
SKIP_WEIGHTS="${SKIP_WEIGHTS:-0}"

# ---------------- helpers ----------------
have() { command -v "$1" &>/dev/null; }

maybe_sudo() {
  if have sudo; then echo sudo; else echo ""; fi
}

install_miniforge_if_needed() {
  if have conda; then
    # shellcheck disable=SC1091
    source "$(conda info --base)/etc/profile.d/conda.sh"
    return
  fi
  echo "==> conda not found. Installing Miniforge (conda-forge)…"
  TMP="$(mktemp -d)"
  pushd "$TMP" >/dev/null
  URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-$(uname -m).sh"
  curl -fsSL "$URL" -o miniforge.sh
  bash miniforge.sh -b -p "$HOME/miniforge3"
  # shellcheck disable=SC1091
  source "$HOME/miniforge3/etc/profile.d/conda.sh"
  conda init bash || true
  popd >/dev/null
}

ensure_basic_system_tools() {
  echo "==> Ensuring git/curl/ffmpeg prerequisites (ffmpeg via conda later)…"
  local SUDO; SUDO="$(maybe_sudo)"
  if have apt-get; then
    $SUDO apt-get update -y
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git curl ca-certificates build-essential pkg-config
  elif have yum; then
    $SUDO yum install -y git curl ca-certificates gcc gcc-c++ make pkgconfig
  else
    echo "Warning: Unknown package manager. Please ensure build tools, git, and curl are installed."
  fi
}

create_and_activate_env() {
  echo "==> Creating/activating conda env: ${ENV_NAME} (python=${PYTHON_VERSION})"
  if ! conda env list | grep -qE "^\s*${ENV_NAME}\s"; then
    conda create -y -n "${ENV_NAME}" "python=${PYTHON_VERSION}"
  fi
  conda activate "${ENV_NAME}"
}

install_step1_torch_xformers() {
  echo "==> [1] Installing torch/torchvision/torchaudio (cu121) and xformers"
  pip install --upgrade pip setuptools wheel
  pip install \
    "torch==${TORCH_VER}" "torchvision==${TV_VER}" "torchaudio==${TA_VER}" \
    --index-url "${CUDA_WHL_INDEX}"
  pip install -U "xformers==${XFORMERS_VER}" --index-url "${CUDA_WHL_INDEX}"
}

install_step2_flash_attn() {
  echo "==> [2] Installing Flash-Attn prerequisites and flash_attn"
  pip install 'misaki[en]'
  pip install ninja
  pip install psutil
  pip install packaging
  pip install wheel
  pip install "flash_attn==${FLASH_ATTN_VER}"
}

install_step3_other_deps() {
  echo "==> [3] Installing other dependencies (requirements.txt + librosa via conda-forge)"
  pip install -r requirements.txt
  conda install -y -c conda-forge librosa
}

install_step4_ffmpeg() {
  echo "==> [4] Installing ffmpeg (prefer conda-forge, fallback to yum)"
  if conda install -y -c conda-forge ffmpeg; then
    echo "ffmpeg installed via conda-forge."
    return
  fi
  if have yum; then
    local SUDO; SUDO="$(maybe_sudo)"
    $SUDO yum install -y ffmpeg ffmpeg-devel
  else
    echo "ffmpeg conda install failed and yum not available. Please install ffmpeg manually."
  fi
}

setup_hf_cli() {
  echo "==> Installing huggingface-cli"
  pip install -U "huggingface_hub[cli]"
  if [[ -n "${HF_TOKEN}" ]]; then
    echo "==> Logging in to Hugging Face with provided token"
    huggingface-cli login --token "${HF_TOKEN}" --add-to-git-credential || true
  fi
}

download_models() {
  echo "==> Downloading models into ${WEIGHTS_DIR}"
  mkdir -p "${WAN_DIR}" "${W2V2_DIR}" "${IT_DIR}"
  # Wan2.1 base
  huggingface-cli download Wan-AI/Wan2.1-I2V-14B-480P --local-dir "${WAN_DIR}"
  # chinese-wav2vec2-base (two commands as in the doc)
  huggingface-cli download TencentGameMate/chinese-wav2vec2-base --local-dir "${W2V2_DIR}"
  huggingface-cli download TencentGameMate/chinese-wav2vec2-base model.safetensors \
    --revision refs/pr/1 --local-dir "${W2V2_DIR}"
  # MeiGen-InfiniteTalk
  huggingface-cli download MeiGen-AI/InfiniteTalk --local-dir "${IT_DIR}"
}

summary() {
  cat <<EOF

============================================================
 InfiniteTalk bootstrap complete.

 Conda env: ${ENV_NAME}
 Activate with:
   conda activate ${ENV_NAME}

 Model weights directory:
   ${WEIGHTS_DIR}
   - Wan2.1:       ${WAN_DIR}
   - Wav2Vec2:     ${W2V2_DIR}
   - InfiniteTalk: ${IT_DIR}

 Next steps:
   # CLI usage/help
   python generate_infinitetalk.py --help

   # Or start the demo (if provided by the repo)
   python app.py
============================================================
EOF
}

# ---------------- run ----------------
ensure_basic_system_tools
install_miniforge_if_needed
# shellcheck disable=SC1091
source "$(conda info --base)/etc/profile.d/conda.sh"
create_and_activate_env

install_step1_torch_xformers
install_step2_flash_attn
install_step3_other_deps
install_step4_ffmpeg

setup_hf_cli
if [[ "${SKIP_WEIGHTS}" != "1" ]]; then
  download_models
else
  echo "==> Skipping model downloads (SKIP_WEIGHTS=1)."
fi

summary