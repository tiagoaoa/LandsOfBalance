"""Submit once, inspect, and fetch a Meshy multiview source mesh.

Default invocation only writes the reviewable request manifest.
Credentials come from MESHY_API_KEY or --key-file; never saved in the project.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[2]
REF = ROOT / 'tools/art/reference/helmeted_lizard'
OUT = ROOT / 'tools/art/source/helmeted_lizard'
API = 'https://api.meshy.ai/openapi/v1/multi-image-to-3d'
VIEWS = ['front', 'left', 'back', 'right']
OPTIONS = {
    'ai_model': 'meshy-6',
    'should_texture': True,
    'enable_pbr': True,
    'texture_resolution': '4k',
    'should_remesh': False,
    'pose_mode': 'a-pose',
    'image_enhancement': False,
    'remove_lighting': True,
    'target_formats': ['glb'],
}


def request(url, key, data=None):
    body = json.dumps(data).encode() if data is not None else None
    req = Request(url, data=body, headers={
        'Authorization': 'Bearer ' + key,
        'Content-Type': 'application/json',
    })
    try:
        with urlopen(req, timeout=120) as response:
            return json.load(response)
    except HTTPError as e:
        raise SystemExit('Meshy HTTP %d: %s' % (e.code, e.read().decode()))


def manifest():
    images = []
    for name in VIEWS:
        path = REF / (name + '.png')
        images.append({
            'path': str(path.relative_to(ROOT)),
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
        })
    return {
        'endpoint': API, 'options': OPTIONS, 'images': images,
        'estimated_credits': 30,
        'pricing_source': 'https://docs.meshy.ai/en/api/pricing',
        'next_step': 'Blender topology inspection, articulated mouth, skinning and combat calibration.',
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['prepare', 'submit', 'status', 'download'],
                   nargs='?', default='prepare')
    p.add_argument('--key-file', type=Path)
    args = p.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    spec = manifest()
    (REF / 'meshy_request.json').write_text(json.dumps(spec, indent=2) + '\n')
    if args.action == 'prepare':
        print(json.dumps(spec, indent=2))
        return
    key = (args.key_file.read_text().strip() if args.key_file
           else os.environ.get('MESHY_API_KEY', '').strip())
    if not key:
        raise SystemExit('Set MESHY_API_KEY or provide --key-file. No request sent.')
    job = OUT / 'meshy_job.json'
    if args.action == 'submit':
        if job.exists():
            raise SystemExit('Job already recorded; use status/download to avoid a second charge.')
        payload = dict(OPTIONS)
        payload['image_urls'] = [
            'data:image/png;base64,' + base64.b64encode((ROOT / im['path']).read_bytes()).decode()
            for im in spec['images']]
        # A timeout can occur after billing. Keep the reservation so a rerun
        # cannot silently submit and charge a second job.
        job.write_text(json.dumps({'id': None, 'status': 'SUBMITTING',
                                   'request': spec}, indent=2) + '\n')
        result = request(API, key, payload)
        job.write_text(json.dumps({'id': result['result'], 'request': spec}, indent=2) + '\n')
        print('Submitted one task:', result['result'])
        return
    data = json.loads(job.read_text())
    if not data['id']:
        raise SystemExit('Submission outcome unknown. Recover the task ID from Meshy before retrying.')
    result = request(API + '/' + data['id'], key)
    data['status'] = result['status']
    data['progress'] = result.get('progress', 0)
    data['task_error'] = result.get('task_error')
    job.write_text(json.dumps(data, indent=2) + '\n')
    print(data['status'], data['progress'], data['task_error'] or '')
    if args.action == 'download':
        if data['status'] != 'SUCCEEDED':
            raise SystemExit('Generation is not ready; no model downloaded.')
        url = result['model_urls']['glb']
        if not url.startswith('https://'):
            raise SystemExit('Unexpected non-HTTPS model URL.')
        path = OUT / 'meshy_source.glb'
        with urlopen(url, timeout=120) as response, path.open('wb') as f:
            while chunk := response.read(1024*1024):
                f.write(chunk)
        with path.open('rb') as f:
            if f.read(4) != b'glTF':
                raise SystemExit('Downloaded file is not a GLB.')
        print('Downloaded', path)


if __name__ == '__main__':
    main()
