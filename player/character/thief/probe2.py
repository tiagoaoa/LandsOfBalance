import numpy as np
from PIL import Image
SP="/tmp/claude-1000/-home-talves-mthings-LandsOfBalance/749a8653-c369-44b9-b617-9c464a65ee06/scratchpad/"
SRC="/home/talves/mthings/LandsOfBalance/player/character/archer/Archer.fbm/"
d=np.load(SP+"Thief_Body_pos2.npz"); P=d['P']; M=d['M']>0
x,y,z=P[...,0],P[...,1],P[...,2]; ax=np.abs(x)
img=np.asarray(Image.open(SRC+"FemaleFitA_Body_diffuse.png").convert("RGB"),np.float32)/255.
r,g,b=img[...,0],img[...,1],img[...,2]
lum=img@np.array([0.2126,0.7152,0.0722],np.float32)
mxx=img.max(-1); mnn=img.min(-1); sat=np.where(mxx>1e-5,(mxx-mnn)/np.maximum(mxx,1e-5),0)
face=M&(z>1.53)&(z<1.75)&(y<-0.02)&(ax<0.09)
print("--- darkest 4% of the central face, by height ---")
cen=face&(ax<0.030)
thr=np.percentile(lum[cen],4)
dk=cen&(lum<thr)
h,_=np.histogram(z[dk],bins=np.arange(1.53,1.72,0.005))
for i,v in enumerate(h):
    if v>200: print(f"  z {1.53+i*0.005:.3f} {v}")
print("--- reddest (vermilion) by height ---")
red=face&(ax<0.035)&(r>g*1.30)&(sat>0.28)
h,_=np.histogram(z[red],bins=np.arange(1.53,1.72,0.005))
for i,v in enumerate(h):
    if v>300: print(f"  z {1.53+i*0.005:.3f} {v}")
print("--- brow: darkest 12% between 1.66 and 1.74 ---")
bb=face&(ax<0.070)&(z>1.655)&(z<1.745)
thr=np.percentile(lum[bb],12); dk=bb&(lum<thr)
h,_=np.histogram(z[dk],bins=np.arange(1.655,1.745,0.005))
for i,v in enumerate(h):
    if v>200: print(f"  z {1.655+i*0.005:.3f} {v}")
