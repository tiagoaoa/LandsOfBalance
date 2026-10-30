#Run the open-weight multiview model on our own GPU worker.
import argparse
import gc
import hashlib
import json
import time
from pathlib import Path

SHAPE_REV = '3a761b539b29fe4ff64714813aa9560fd66f5de0'
PAINT_REV = '9cd649ba6913f7a852e3286bad86bfa9a2d83dcf'
VIEWS = ['front', 'left', 'back', 'right']


def checkpoint(repo, revision, patterns):
    from huggingface_hub import snapshot_download
    return snapshot_download(repo, revision=revision,
                             allow_patterns=patterns)


def load_views(ref, out):
    from PIL import Image
    from hy3dgen.rembg import BackgroundRemover
    remover = BackgroundRemover()
    images = {}
    for name in VIEWS:
        image = Image.open(ref / (name + '.png')).convert('RGB')
        image = remover(image)
        image.save(out / (name + '_masked.png'))
        images[name] = image
    return images


def shape_model():
    from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline
    sub = 'hunyuan3d-dit-v2-mv'
    path = checkpoint('tencent/Hunyuan3D-2mv', SHAPE_REV,
                      [sub + '/config.yaml', sub + '/model.fp16.safetensors'])
    return Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(
        path, subfolder=sub, variant='fp16', use_safetensors=True)


def generate_shapes(images, args):
    import torch
    from hy3dgen.shapegen import FaceReducer, DegenerateFaceRemover
    pipe = shape_model()
    for seed in args.seeds:
        mesh = pipe(image=images, num_inference_steps=args.steps,
                    octree_resolution=args.resolution, num_chunks=10000,
                    generator=torch.Generator('cuda').manual_seed(seed),
                    output_type='trimesh')[0]
        mesh.export(args.out / ('shape_%d_raw.glb' % seed))
        mesh = DegenerateFaceRemover()(mesh)
        mesh = FaceReducer()(mesh, max_facenum=args.faces)
        mesh.export(args.out / ('shape_%d.glb' % seed))
        print('SHAPE_SAVED', seed, len(mesh.vertices), len(mesh.faces), flush=True)
    del pipe
    gc.collect()
    torch.cuda.empty_cache()


def paint_model():
    from hy3dgen.texgen.pipelines import Hunyuan3DPaintPipeline
    from hy3dgen.texgen.pipelines import Hunyuan3DTexGenConfig
    sub = 'hunyuan3d-paint-v2-0-turbo'
    path = Path(checkpoint('tencent/Hunyuan3D-2', PAINT_REV,
                          ['hunyuan3d-delight-v2-0/*', sub + '/*']))
    cfg = Hunyuan3DTexGenConfig(str(path / 'hunyuan3d-delight-v2-0'),
                                str(path / sub), sub)
    cfg.texture_size = 4096
    return Hunyuan3DPaintPipeline(cfg)


def paint_shapes(images, args):
    import torch
    import trimesh
    pipe = paint_model()
    pipe.enable_model_cpu_offload()
    for seed in args.seeds:
        torch.manual_seed(seed)
        mesh = trimesh.load(args.out / ('shape_%d.glb' % seed), force='mesh')
        mesh = pipe(mesh, image=[images[n] for n in VIEWS])
        mesh.export(args.out / ('textured_%d.glb' % seed))
        print('TEXTURE_SAVED', seed, flush=True)


def record(args, elapsed):
    import torch
    files = {}
    for path in sorted(args.out.glob('*.glb')):
        files[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    data = {'shape_model': 'tencent/Hunyuan3D-2mv', 'shape_revision': SHAPE_REV,
            'paint_model': 'tencent/Hunyuan3D-2', 'paint_revision': PAINT_REV,
            'gpu': torch.cuda.get_device_name(), 'seeds': args.seeds,
            'steps': args.steps, 'resolution': args.resolution,
            'elapsed_seconds': elapsed, 'sha256': files}
    (args.out / 'generation.json').write_text(json.dumps(data, indent=2) + '\n')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--ref', type=Path, default=Path('reference'))
    p.add_argument('--out', type=Path, default=Path('output'))
    p.add_argument('--seeds', type=int, nargs='+', default=[20261009])
    p.add_argument('--steps', type=int, default=50)
    p.add_argument('--resolution', type=int, default=512)
    p.add_argument('--faces', type=int, default=150000)
    p.add_argument('--stage', choices=['shape', 'texture', 'all'], default='all')
    p.add_argument('--preflight', action='store_true')
    args = p.parse_args()
    for name in VIEWS:
        if not (args.ref / (name + '.png')).is_file():
            p.error('Missing view: ' + name)
    if args.preflight:
        print('INPUTS_OK', ', '.join(VIEWS))
        return
    import torch
    if not torch.cuda.is_available():
        raise SystemExit('This worker needs an NVIDIA GPU; no generation started.')
    args.out.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    images = load_views(args.ref, args.out)
    if args.stage in ['shape', 'all']:
        generate_shapes(images, args)
    if args.stage in ['texture', 'all']:
        paint_shapes(images, args)
    record(args, time.monotonic() - start)


if __name__ == '__main__':
    main()
