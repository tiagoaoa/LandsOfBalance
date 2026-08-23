import numpy as np
from PIL import Image

SP="/tmp/claude-1000/-home-talves-mthings-LandsOfBalance/749a8653-c369-44b9-b617-9c464a65ee06/scratchpad/"
SRC="/home/talves/mthings/LandsOfBalance/player/character/archer/Archer.fbm/"
N=2048

def blur(a, f=16):
    h=a.shape[0]//f
    small=a.reshape(h,f,h,f).mean((1,3))
    idx=(np.arange(a.shape[0])+0.5)/f-0.5
    i0=np.clip(np.floor(idx).astype(int),0,h-1); i1=np.clip(i0+1,0,h-1)
    t=np.clip(idx-i0,0,1)
    tmp=small[i0]*(1-t)[:,None]+small[i1]*t[:,None]
    return tmp[:,i0]*(1-t)[None,:]+tmp[:,i1]*t[None,:]

def upscale_mask(a, n):
    # nearest upscale from 1024 -> n
    f = n // a.shape[0]
    return np.repeat(np.repeat(a, f, axis=0), f, axis=1)

d=np.load(SP+"Thief_Clothes_pos.npz")
P=upscale_mask(d['P'], N); M=upscale_mask(d['M'], N)>0
x,y,z = P[...,0], P[...,1], P[...,2]
ax=np.abs(x)

img=np.asarray(Image.open(SRC+"Erika_Archer_Clothes_diffuse.png").convert("RGB"), np.float32)/255.0
lum=img@np.array([0.2126,0.7152,0.0722],np.float32)
mx=img.max(-1); mn=img.min(-1)
sat=np.where(mx>1e-5,(mx-mn)/np.maximum(mx,1e-5),0.0)

# ---- zones -------------------------------------------------------------
ARM   = ax>0.215
zone=np.zeros(img.shape[:2], np.uint8)   # 0 = untouched
SLEEVE, BRACER, HOOD, TORSO, SKIRT, PANTS, BOOT = 1,2,3,4,5,6,7
zone[M & ARM & (ax<=0.46)]=SLEEVE
zone[M & ARM & (ax> 0.46)]=BRACER
body = M & ~ARM
zone[body & (z>=1.60)]=HOOD
zone[body & (z>=1.15) & (z<1.60)]=TORSO
zone[body & (z>=0.88) & (z<1.15)]=SKIRT
zone[body & (z>=0.52) & (z<0.88)]=PANTS
zone[body & (z< 0.52)]=BOOT

# ---- target palette (sRGB 0-1) ----------------------------------------
TGT={
 SLEEVE:(0.60,0.55,0.42),   # tan linen
 BRACER:(0.165,0.108,0.072),  # dark leather
 HOOD:  (0.160,0.106,0.072),  # brown leather hood
 TORSO: (0.150,0.098,0.066),  # brown leather jerkin
 SKIRT: (0.155,0.103,0.069),
 PANTS: (0.125,0.10,0.085), # near-black brown
 BOOT:  (0.215,0.142,0.092),
}
# linen keeps its folds but not the leather's near-black creases
FLOOR={SLEEVE:0.40,HOOD:0.62}
CEIL={SLEEVE:1.55,BOOT:1.25,SKIRT:1.35,PANTS:1.45,TORSO:1.60,HOOD:1.10}
out=img.copy()
lum_soft=0.80*blur(lum,16)+0.20*lum
for zid,tgt in TGT.items():
    m = zone==zid
    if not m.any(): continue
    L=(lum_soft if zid==HOOD else lum)[m]
    L0=np.percentile(L,72)
    if L0<1e-3: L0=1e-3
    f=FLOOR.get(zid,0.0)
    k=(f+(1.0-f)*(L/L0))[:,None]
    k=np.clip(k,0.0,CEIL.get(zid,1.9))
    c=np.array(tgt,np.float32)[None,:]*k
    out[m]=np.clip(c,0,1)

# the linen tunic shows between the front skirt panels
def ss(e0,e1,v):
    t=np.clip((v-e0)/(e1-e0),0,1); return t*t*(3-2*t)
wt = (zone==SKIRT)*ss(0.052,0.026,np.abs(x))*ss(0.010,-0.030,y)*ss(0.940,0.968,z)*ss(1.140,1.105,z)
if wt.max()>0:
    L0t=max(np.percentile(lum[wt>0.5],72),1e-3)
    lin=np.clip(np.clip(0.42+0.58*(lum/L0t),0,1.10)[...,None]*np.array([0.335,0.295,0.220],np.float32)[None,None,:],0,1)
    out=out*(1-wt[...,None])+lin*wt[...,None]

# keep metal: low-sat bright original pixels stay steel
metal = (sat<0.085)&(lum>0.46)&(zone>0)&(zone!=SLEEVE)
steel = np.clip((lum[metal]*1.05)[:,None]*np.array([0.80,0.79,0.76],np.float32)[None,:],0,1)
out[metal]=0.70*out[metal]+0.30*steel

# red sash -> leather belt: hue near red with decent sat inside torso/skirt
r,g,b = img[...,0],img[...,1],img[...,2]
red = (r>g*1.35)&(r>b*1.35)&(sat>0.25)&M
out[red]=np.clip((0.45+0.55*(lum[red]/max(np.percentile(lum[red],60),1e-3)))[:,None]*np.array([0.30,0.20,0.13],np.float32)[None,:],0,1)

Image.fromarray((np.clip(out,0,1)*255).astype(np.uint8)).save(SP+"Thief_Clothes_diffuse.png")

# zone debug
pal={0:(20,20,20),SLEEVE:(240,220,140),BRACER:(200,90,40),HOOD:(90,220,90),TORSO:(70,120,240),
     SKIRT:(230,120,220),PANTS:(120,60,200),BOOT:(240,60,60)}
dbg=np.zeros((N,N,3),np.uint8)
for k,v in pal.items(): dbg[zone==k]=v
Image.fromarray(dbg).resize((768,768), Image.NEAREST).save(SP+"zone_dbg.png")
print("zone texel counts", {k:int((zone==k).sum()) for k in pal})
