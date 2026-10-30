#!/usr/bin/env bash
#TRELLIS.2 (MIT) in its own conda env, beside the Hunyuan install.
#Any NVIDIA Linux worker: conda_cuda124.sh supplies Python 3.10, CUDA 12.4, torch 2.6.
set -eo pipefail
job_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$job_dir"
export MAX_JOBS=16
apt-get update -qq
apt-get install -y --no-install-recommends git build-essential libgl1 libglib2.0-0 libjpeg-dev
if [[ ! -d TRELLIS.2 ]]; then
    git clone -b main https://github.com/microsoft/TRELLIS.2.git --recursive TRELLIS.2
fi
bash conda_cuda124.sh trellis2
source /opt/miniforge/etc/profile.d/conda.sh
conda activate trellis2
export CUDA_HOME="$CONDA_PREFIX"
#flash-attn must see the installed torch: build it without pip's isolation
#(setup.sh's plain `pip install flash-attn` fails with "No module named torch").
python -c 'import flash_attn' 2>/dev/null || {
    python -m pip install packaging psutil ninja wheel
    python -m pip install flash-attn==2.7.3 --no-build-isolation
}
cd TRELLIS.2
#setup.sh is sourced (it calls `return`); the env above already holds torch.
. ./setup.sh --basic --nvdiffrast --nvdiffrec --cumesh --o-voxel --flexgemm
#setup.sh leaves transformers unpinned; 5.x no longer exposes the DINOv3 layer
#list TRELLIS.2's feature extractor walks (`model.layer`). 4.57 has DINOv3 and it.
python -m pip install 'transformers==4.57.1'
python -c 'import torch, o_voxel; from trellis2.pipelines import Trellis2ImageTo3DPipeline; print(torch.cuda.get_device_name())'
