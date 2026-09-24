#!/usr/bin/env bash
# Photo -> MakeHuman character.  Needs Blender 5.x with the MPFB extension and the
# "makehuman system assets" pack, plus a venv with mediapipe==0.10.21 (1.0 crashes).
#   ./build.sh /tmp/nego_mh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); S=${1:-/tmp/nego_mh}; mkdir -p "$S"
PY=${PY:-$HERE/../../../.venv-mediapipe/bin/python}
[ -f "$S/face_landmarker.task" ] || curl -sSL -o "$S/face_landmarker.task" \
  https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task
python3 -c "from PIL import Image; Image.open('$HERE/../../../NegoThief.jpg').crop((440,60,580,220)).resize((560,640),Image.LANCZOS).save('$S/photo_crop4x.png')"
cp "$HERE/render_head.py" "$S/"
blender -b --python "$HERE/mh_base.py" -- "$S"                      # macro base + ortho render
"$PY" "$HERE/lm_photo.py" "$S" "$S/photo_crop4x.png" "$S/lm_photo.json"
"$PY" "$HERE/lm_photo.py" "$S" "$S/base_front.png"   "$S/lm_base.json"
"$PY" "$HERE/fit_face.py" "$S"                                      # -> fit_weights.json
blender -b "$S/mpfb_base.blend" --python "$HERE/apply_fit.py" -- "$S" fit1
blender -b "$S/fit1.blend" --python "$HERE/dump_uv.py" -- "$S"
"$PY" "$HERE/posmap_mh.py" "$S" fit1 4096
"$PY" "$HERE/project_mh.py" "$S" fit1                               # -> nego_skin_diffuse.png
blender -b "$S/fit1.blend" --python "$HERE/apply_tex.py" -- "$S" fit1
echo "result: $S/fit1_tex.blend  render: $S/fit1_tex.png"
