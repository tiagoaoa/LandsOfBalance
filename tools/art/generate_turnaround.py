"""Generate a source mesh with Microsoft's public TRELLIS.2 demo.

Run: uv run --with gradio_client tools/art/generate_turnaround.py
The generated mesh still needs Blender cleanup, a mouth interior and skinning.
"""
import json
import shutil
from pathlib import Path

from gradio_client import Client, handle_file

ROOT = Path(__file__).resolve().parents[2]
REF = ROOT / 'tools/art/reference/helmeted_lizard'
OUT = ROOT / 'tools/art/source/helmeted_lizard'
OUT.mkdir(parents=True, exist_ok=True)
model = OUT / 'trellis_source.glb'
if model.exists():
    raise SystemExit('Source already exists; refusing a duplicate generation.')

client = Client('microsoft/TRELLIS.2', download_files=str(OUT / 'download'))
client.predict(api_name='/start_session')
print('PREPROCESSING', flush=True)
prepared = client.predict(handle_file(str(REF / 'front_three_quarter.png')),
                          api_name='/preprocess_image')
print('GENERATING', flush=True)
preview = client.predict(
    prepared, 20261009, '1024',
    7.5, .7, 12, 5.0, 7.5, .5, 12, 3.0, 1.0, 0.0, 12, 3.0,
    api_name='/image_to_3d')
(OUT / 'preview.html').write_text(preview)
print('EXTRACTING', flush=True)
files = client.predict(150000, 4096, api_name='/extract_glb')
shutil.copy2(files[0], model)
(OUT / 'generation.json').write_text(json.dumps({
    'service': 'https://huggingface.co/spaces/microsoft/TRELLIS.2',
    'input': str(REF.relative_to(ROOT) / 'front_three_quarter.png'),
    'seed': 20261009, 'resolution': 1024,
    'target_triangles': 150000, 'texture_size': 4096,
}, indent=2) + '\n')
print('GENERATED', model, flush=True)
