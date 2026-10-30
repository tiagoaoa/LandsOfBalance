#Single-image TRELLIS.2 (MIT) generation of the lizard titan on our GPU worker.
#Run inside the trellis2 conda env, from the TRELLIS.2 checkout.
import argparse
import hashlib
import json
import os
import time
from pathlib import Path

os.environ.setdefault('PYTORCH_CUDA_ALLOC_CONF', 'expandable_segments:True')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--ref', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--views', nargs='+', default=['three_quarter', 'front'])
    p.add_argument('--seeds', type=int, nargs='+', default=[20261024, 7])
    p.add_argument('--pipeline', default='1536_cascade')
    p.add_argument('--faces', type=int, default=300000)
    args = p.parse_args()
    import torch
    import o_voxel
    from PIL import Image
    from trellis2.pipelines import Trellis2ImageTo3DPipeline
    import trellis2.pipelines.rembg as rembg

    class NoBackgroundRemover:
        #briaai/RMBG-2.0 is gated and non-commercial. The views arrive cut out
        #(tools/art/prepare_titan_views.py), and an image with transparency
        #never reaches the remover; this only keeps the pipeline from loading it.
        def __init__(self, *a, **k):
            pass

        def to(self, *a, **k):
            return self

        def cpu(self):
            return self

        def cuda(self):
            return self

        def __call__(self, image):
            raise RuntimeError('views must arrive with an alpha cut-out')

    for name in dir(rembg):
        if isinstance(getattr(rembg, name), type):
            setattr(rembg, name, NoBackgroundRemover)
    args.out.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    pipe = Trellis2ImageTo3DPipeline.from_pretrained('microsoft/TRELLIS.2-4B')
    pipe.cuda()
    done = []
    for view in args.views:
        cut = args.ref / (view + '_rgba.png')
        image = Image.open(cut).convert('RGBA') if cut.is_file() else Image.open(args.ref / (view + '.png')).convert('RGB')
        for seed in args.seeds:
            t = time.monotonic()
            mesh = pipe.run(image, seed=seed, pipeline_type=args.pipeline)[0]
            mesh.simplify(16777216)   # nvdiffrast limit
            glb = o_voxel.postprocess.to_glb(
                vertices=mesh.vertices, faces=mesh.faces, attr_volume=mesh.attrs,
                coords=mesh.coords, attr_layout=mesh.layout, voxel_size=mesh.voxel_size,
                aabb=[[-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]],
                decimation_target=args.faces, texture_size=4096,
                remesh=True, remesh_band=1, remesh_project=0, verbose=True)
            name = 'trellis_%s_%d.glb' % (view, seed)
            glb.export(str(args.out / name), extension_webp=False)
            done.append(name)
            print('TRELLIS_SAVED', name, '%.0fs' % (time.monotonic() - t), flush=True)
            torch.cuda.empty_cache()
    files = {n: hashlib.sha256((args.out / n).read_bytes()).hexdigest() for n in done}
    (args.out / 'trellis.json').write_text(json.dumps({
        'model': 'microsoft/TRELLIS.2-4B (MIT)', 'pipeline': args.pipeline,
        'views': args.views, 'seeds': args.seeds, 'faces': args.faces,
        'gpu': torch.cuda.get_device_name(), 'elapsed_seconds': time.monotonic() - start,
        'sha256': files}, indent=2) + '\n')


if __name__ == '__main__':
    main()
