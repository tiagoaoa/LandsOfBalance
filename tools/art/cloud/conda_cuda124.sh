#!/usr/bin/env bash
#A conda env with Python 3.10, the CUDA 12.4 toolkit and PyTorch 2.6 (cu124).
#Vast's base images ship a CUDA 13 toolkit; PyTorch refuses to build cu124
#extensions with it, so each model gets its own matching nvcc here.
#Usage: bash conda_cuda124.sh ENV_NAME
set -eo pipefail
env_name="$1"
base=/opt/miniforge
if [[ ! -x $base/bin/conda ]]; then
    curl -fsSL -o /tmp/miniforge.sh \
        https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh
    bash /tmp/miniforge.sh -b -p $base
fi
source $base/etc/profile.d/conda.sh
if ! conda env list | grep -q "^$env_name "; then
    conda create -y -n "$env_name" python=3.10
    conda install -y -n "$env_name" -c nvidia/label/cuda-12.4.1 cuda-toolkit
fi
conda activate "$env_name"
python -m pip install --upgrade pip
python -m pip install torch==2.6.0 torchvision==0.21.0 --index-url https://download.pytorch.org/whl/cu124
python -c 'import torch; print("TORCH", torch.__version__, torch.version.cuda, torch.cuda.is_available())'
nvcc --version | tail -1
