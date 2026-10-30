#Package the four input views and worker code, without credentials or game files.
import hashlib
import json
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
import sys
#The lizard titan sheet by default; pass another reference folder to override.
REF = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'tools/art/reference/lizard_titan'
OUT = ROOT / 'build/art-models/boss-job.tar.gz'
VIEWS = ['front', 'left', 'back', 'right', 'three_quarter',
         'front_rgba', 'left_rgba', 'back_rgba', 'right_rgba', 'three_quarter_rgba']


def files():
    for name in ['hunyuan_boss.py', 'requirements.txt',
                 'setup_hunyuan.sh', 'run_job.sh',
                 'trellis_boss.py', 'setup_trellis.sh', 'run_trellis.sh',
                 'conda_cuda124.sh']:
        yield HERE / name, 'boss-job/' + name
    for name in VIEWS:
        if (REF / (name + '.png')).is_file():
            yield REF / (name + '.png'), 'boss-job/reference/' + name + '.png'


def main():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    hashes = {}
    with tarfile.open(OUT, 'w:gz') as archive:
        for src, dest in files():
            archive.add(src, arcname=dest)
            hashes[dest] = hashlib.sha256(src.read_bytes()).hexdigest()
    meta = OUT.with_suffix('.manifest.json')
    meta.write_text(json.dumps(hashes, indent=2) + '\n')
    print(OUT, OUT.stat().st_size, 'bytes')


if __name__ == '__main__':
    main()
