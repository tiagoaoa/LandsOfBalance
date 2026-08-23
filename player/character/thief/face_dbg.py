import numpy as np
from PIL import Image
SP="/tmp/claude-1000/-home-talves-mthings-LandsOfBalance/749a8653-c369-44b9-b617-9c464a65ee06/scratchpad/"
d=np.load(SP+"Thief_Body_pos2.npz"); P=d['P']; M=d['M']>0
x,y,z=P[...,0],P[...,1],P[...,2]; ax=np.abs(x)
base=np.asarray(Image.open(SP+"Thief_Body_diffuse.png").convert("RGB"),np.float32)/255.
out=base*0.55
face=M&(z>1.50)&(y<0.02)&(ax<0.10)
# 5 mm stripes up the face, alternating, labelled by colour every 25 mm
for lo in np.arange(1.535,1.700,0.005):
    band=face&(z>=lo)&(z<lo+0.005)
    i=int(round((lo-1.535)/0.005))
    col=[(1,0,0),(0,1,0),(0,0.6,1),(1,1,0),(1,0,1)][i%5]
    out[band]=np.array(col,np.float32)*(0.55 if (i//5)%2 else 1.0)
Image.fromarray((np.clip(out,0,1)*255).astype(np.uint8)).save(SP+"Thief_Face_dbg.png")
print("z stripes: 1.535 red, 1.540 green, 1.545 blue, 1.550 yellow, 1.555 magenta, then dim for the next five, repeating")
