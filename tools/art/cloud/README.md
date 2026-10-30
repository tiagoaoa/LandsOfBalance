# Boss generation on a GPU worker

This runs [Hunyuan3D-2](https://github.com/Tencent-Hunyuan/Hunyuan3D-2) from its
downloadable weights. There is no paid model API. A GPU provider bills for the
machine, disk and transfer. The source and weights use Tencent's community
license; the upstream repository includes the complete terms.

The worker uses all four cardinal views from the supplied turnaround. It keeps
the raw geometry, reduces a copy to 150,000 faces and generates a 4096² diffuse
texture with Paint Turbo. Separate jaw geometry, rigging, collision calibration
and PBR maps still need Blender work. Do not install an unreviewed generated
mesh as the runtime boss.

## Prepare

```bash
python3 tools/art/cloud/pack_job.py
python3 tools/art/cloud/hunyuan_boss.py --preflight \
    --ref tools/art/reference/helmeted_lizard
python3 tests/test_boss_cloud.py
```

The archive in `build/art-models/boss-job.tar.gz` contains four PNGs and four
worker files, with no credentials or unrelated game files. Its companion
manifest records hashes. `requirements.txt` pins direct dependencies; code
and weight revisions are pinned in the worker files.

## Run

Use a disposable Linux worker with an NVIDIA GPU of at least 24 GB, at least
32 GB system RAM and 80 GB disk. The expected image is
`pytorch/pytorch:2.6.0-cuda12.4-cudnn9-devel`; the CUDA development tools are
needed to compile the texture rasterizer.

The provider account, SSH public key and spend limit must be configured before
renting. Read the live quote, including storage and transfer. Create only one
instance for this run, with a label starting `lob-boss-`, and record its ID.
The 2026-10-09 read-only search found a South Korean RTX 4090 offer at
$0.42815/hour including 80 GB disk, with transfer at $0.00026042/GB inbound and
$0.00039063/GB outbound. A 90-minute run with 30 GB inbound and 1 GB outbound
was estimated at $0.65. This is a dated estimate, not a spending guarantee.

Once the instance is running:

```bash
python3 tools/art/cloud/run_vast_job.py INSTANCE_ID --minutes 90 \
    --key-file /path/to/local/vast-key
```

The controller can also read `VAST_API_KEY` or the Vast CLI's standard local
key file. It keeps that credential on the local machine. It sends the bundle
through SSH, runs the job, downloads output into
`tools/art/source/helmeted_lizard/vast_INSTANCE_ID`, checks SHA-256 hashes and
destroys the dedicated instance. It rejects an instance whose label does not
start with `lob-boss-`.

On a failed download or failed hash check, it requests that compute stop and
retains the remote files for recovery. Disk billing continues in that case;
recover the files and destroy the instance promptly. The local controller must
remain running with network access. A process timeout inside the container
does not stop Vast billing. Confirm the final `INSTANCE_DESTROYED` result and
the provider's instance state.

On an already owned/rented GPU host, extract the same archive into its working
directory and run `bash run_job.sh` inside `boss-job`. Installation modifies
that disposable container. Manage that provider's shutdown separately.

## Validation status

Input packaging, Python/shell syntax and dependency resolution were checked
locally. Four mocked lifecycle tests cover verification before deletion,
retention on a bad download, cleanup after worker failure and rejection of an
unrelated instance. The CUDA setup and full generation have not run yet.
