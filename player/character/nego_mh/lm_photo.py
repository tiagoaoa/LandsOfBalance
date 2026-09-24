import sys, json, numpy as np, cv2
import mediapipe as mp
from mediapipe.tasks import python as mpp
from mediapipe.tasks.python import vision
S = sys.argv[1]; photo = sys.argv[2]; out = sys.argv[3]
img = cv2.imread(photo)
opts = vision.FaceLandmarkerOptions(base_options=mpp.BaseOptions(model_asset_path=S+"/face_landmarker.task"),
        num_faces=1, output_facial_transformation_matrixes=True)
lm = vision.FaceLandmarker.create_from_options(opts)
res = lm.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(img, cv2.COLOR_BGR2RGB)))
if not res.face_landmarks: print("NOFACE"); sys.exit(1)
h, w = img.shape[:2]
pts = np.array([[p.x*w, p.y*h, p.z*w] for p in res.face_landmarks[0]])
json.dump({"w": w, "h": h, "pts": pts.tolist(),
           "matrix": res.facial_transformation_matrixes[0].tolist()}, open(out, "w"))
for x, y, _ in pts: cv2.circle(img, (int(x), int(y)), 1, (0, 255, 0), -1)
cv2.imwrite(out.replace(".json", ".png"), img)
print("LM", len(pts), "bbox", pts[:, :2].min(0).round(1).tolist(), pts[:, :2].max(0).round(1).tolist())
