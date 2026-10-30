#!/usr/bin/env bash
#Runtime timeout ends the process, not rental billing. Destroy the instance after.
set -eo pipefail
job_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$job_dir"
export HF_HOME="$job_dir/cache/huggingface"
export PYTHONUNBUFFERED=1
mkdir -p output
timeout --signal=TERM --kill-after=30s 5400 bash setup_trellis.sh > output/trellis_setup.log 2>&1
source /opt/miniforge/etc/profile.d/conda.sh
conda activate trellis2
cd TRELLIS.2
#The worker lives beside the checkout, not in it: put the repo on the path.
export PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}"
timeout --signal=TERM --kill-after=30s 3600 python "$job_dir/trellis_boss.py" \
    --ref "$job_dir/reference" --out "$job_dir/output" "$@" > "$job_dir/output/trellis.log" 2>&1
