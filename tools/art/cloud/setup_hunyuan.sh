#!/usr/bin/env bash
#For a disposable pytorch/pytorch:2.6.0-cuda12.4-cudnn9-devel worker.
set -euo pipefail
job_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$job_dir"
export DEBIAN_FRONTEND=noninteractive
export PIP_DISABLE_PIP_VERSION_CHECK=1
export MAX_JOBS=4
apt-get update -qq
apt-get install -y --no-install-recommends git build-essential libgl1 libopengl0 libglib2.0-0 libgomp1
if [[ ! -d Hunyuan3D-2 ]]; then
    git clone https://github.com/Tencent-Hunyuan/Hunyuan3D-2.git Hunyuan3D-2
fi
git -C Hunyuan3D-2 checkout f8db63096c8282cb27354314d896feba5ba6ff8a
python -m pip install -r requirements.txt
python -m pip install --no-deps --no-build-isolation -e Hunyuan3D-2
cd Hunyuan3D-2/hy3dgen/texgen/custom_rasterizer
python -m pip install --no-build-isolation .
cd ../differentiable_renderer
python -m pip install --no-build-isolation .
cd "$job_dir"
python -c 'import torch, custom_rasterizer; from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline; from hy3dgen.texgen import Hunyuan3DPaintPipeline; print(torch.cuda.get_device_name())'
