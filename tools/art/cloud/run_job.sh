#!/usr/bin/env bash
#Runtime timeout ends the process, not rental billing. Controller must destroy it.
set -euo pipefail
job_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$job_dir"
export HF_HOME="$job_dir/cache/huggingface"
export U2NET_HOME="$job_dir/cache/rembg"
export PYTHONUNBUFFERED=1
export USE_SAGEATTN=0
mkdir -p output
#Base images without a CUDA 12.4 toolkit get one in a conda env first.
if ! python -c 'import torch; assert torch.__version__.startswith("2.6")' 2>/dev/null; then
    bash conda_cuda124.sh hy3d > output/env.log 2>&1
    source /opt/miniforge/etc/profile.d/conda.sh
    conda activate hy3d
    export CUDA_HOME="$CONDA_PREFIX"
fi
timeout --signal=TERM --kill-after=30s 2700 bash setup_hunyuan.sh > output/setup.log 2>&1
timeout --signal=TERM --kill-after=30s 2700 python hunyuan_boss.py "$@" > output/generation.log 2>&1
