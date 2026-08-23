import numpy as np
from PIL import Image

SP="/tmp/claude-1000/-home-talves-mthings-LandsOfBalance/749a8653-c369-44b9-b617-9c464a65ee06/scratchpad/"
SRC="/home/talves/mthings/LandsOfBalance/player/character/archer/Archer.fbm/"
N=2048

def ss(e0,e1,v):
    t=np.clip((v-e0)/(e1-e0),0.0,1.0); return t*t*(3-2*t)

def blur(a, f=16):
    """cheap low-pass: box-average down by f, then bilinear back up"""
    h=a.shape[0]//f
    small=a.reshape(h,f,h,f).mean((1,3))
    idx=(np.arange(a.shape[0])+0.5)/f-0.5
    i0=np.clip(np.floor(idx).astype(int),0,h-1); i1=np.clip(i0+1,0,h-1)
    t=np.clip(idx-i0,0,1)
    tmp=small[i0]*(1-t)[:,None]+small[i1]*t[:,None]
    return tmp[:,i0]*(1-t)[None,:]+tmp[:,i1]*t[None,:]

def dilate(m, r):
    out=m.copy()
    for d in range(1,r+1):
        out[d:,:]|=m[:-d,:]; out[:-d,:]|=m[d:,:]
        out[:,d:]|=m[:,:-d]; out[:,:-d]|=m[:,d:]
    return out

d=np.load(SP+"Thief_Body_pos2.npz"); P=d['P']; M=d['M']>0
x,y,z=P[...,0],P[...,1],P[...,2]
ax=np.abs(x)
de=np.load(SP+"Thief_Eyes_pos2.npz"); ME=de['M']>0; PE=de['P']

img=np.asarray(Image.open(SRC+"FemaleFitA_Body_diffuse.png").convert("RGB"),np.float32)/255.
r,g,b=img[...,0],img[...,1],img[...,2]
lum=img@np.array([0.2126,0.7152,0.0722],np.float32)
mx=img.max(-1); mn=img.min(-1); sat=np.where(mx>1e-5,(mx-mn)/np.maximum(mx,1e-5),0)

# ---------------------------------------------------------------- landmarks
EYE_X, EYE_Y, EYE_Z = 0.0342, -0.0777, 1.6629
CHIN_Z   = 1.546
MOUTH_Z  = 1.5945
NOSE_B_Z = 1.612
NOSE_T_Z = 1.624

# ------------------------------------------------------------------- skin
# The archer's map is a pale, high-contrast painting.  Flatten its broad tonal
# range onto one brown and let only the fine detail through, or the forehead
# blows out to tan while the beard stays black.
SKIN=np.array([0.400,0.277,0.206],np.float32)
Lb=blur(lum,16); det=lum-Lb
# the archer's face art carries painted highlight streaks down the cheeks; keep
# the dark detail (creases, nostrils) and halve the bright detail
det=np.where(det>0, det*0.45, det)
L0=np.percentile(Lb[M],55)
base=np.clip(0.66+0.62*(Lb/max(L0,1e-3)-1.0),0.46,1.24)
out=img.copy()
shade=np.clip(base+0.95*det,0.20,1.55)[...,None]
out[M]=np.clip(SKIN[None,:]*shade[M],0,1)

face = M&(z>1.53)&(y<0.015)&(ax<0.092)

# ------------------------------------------------------------------- lips
# only the vermilion itself, as a soft ellipse around the mouth line
LIP_Z=1.5955
ellipse = np.sqrt((np.abs(z-LIP_Z)/0.0122)**2 + (ax/0.0315)**2)
vermil  = ss(1.35,0.55,ellipse)*face*ss(0.020,-0.030,y)
lipconf = np.clip((r/np.maximum(g,1e-4)-1.14)/0.30,0,1)
wlip    = np.clip(vermil*(0.35+0.65*lipconf),0,1)
wlip    = 0.5*(wlip+blur(wlip,4))
Ll=np.clip(base+1.25*det,0.35,1.4)[...,None]
lipcol=np.clip(np.array([0.268,0.156,0.128],np.float32)[None,None,:]*Ll,0,1)
out=out*(1-wlip[...,None])+lipcol*wlip[...,None]
# a little shade under the lower lip so it reads as a lip and not a decal
undershade = ss(1.5765,1.5825,z)*ss(1.5690,1.5750,z)*ss(0.030,0.018,ax)*face
out=out*(1.0-0.20*undershade)[...,None]

# ------------------------------------------------------------------ brows
u=np.clip((ax-0.010)/0.048,0,1)
zc = 1.6880 + 0.0030*np.sin(np.pi*u)                 # nearly straight, faintly arched
half = 0.0082*ss(0.009,0.019,ax)*ss(0.068,0.055,ax)  # tapers at both ends
brow = face*ss(0.0,1.0,1.0-np.abs(z-zc)/np.maximum(half,1e-6))*(y<-0.02)
brow = np.clip(brow,0,1)

# ------------------------------------------------------------------ beard
# moustache -> corner -> chin patch -> a strap that follows the mandible up to
# the ear, cheeks left almost bare.  Two curves do the work:
uj = np.clip(ax/0.082,0,1)
# two curves bound the beard: the mandible underneath, and how high it climbs
# the cheek.  They must not converge or the beard collapses into a stripe.
JAW  = 1.540 + 0.088*uj**1.35
GAP  = 0.011 + 0.027*(1.0-uj)**1.5      # a strap along the jaw, fuller at the chin
TOP  = JAW + GAP
w_face = ss(TOP+0.006,TOP-0.004,z)*ss(JAW-0.011,JAW+0.001,z)

# moustache follows the upper lip, thinning toward the corners
lip_top = 1.6075 - 0.0115*np.clip(ax/0.033,0,1)**1.6
w_stach = ss(lip_top-0.0010,lip_top+0.0020,z)*ss(lip_top+0.0125,lip_top+0.0090,z)*ss(0.034,0.025,ax)
w_soul  = ss(1.5835,1.5760,z)*ss(0.016,0.010,ax)*ss(1.5640,1.5710,z)
w_cheek = 0.10*ss(TOP+0.026,TOP+0.004,z)
w = np.clip(np.maximum.reduce([w_face,w_stach,w_soul,w_cheek]),0,1)
w *= ss(1.514,1.532,z)                  # nothing on the throat
w *= ss(0.030,-0.020,y)
w *= face
w *= 1.0-np.clip(wlip*1.5,0,1)
rng=np.random.default_rng(11)
# crisp core, speckled fringe: dense hair, not an airbrushed shadow
n1=rng.random((N,N)).astype(np.float32)
n2=blur(rng.random((N,N)).astype(np.float32),8)
grain=np.clip(0.62*n1+0.38*(n2-n2.mean()+0.5),0,1)
w=np.clip((w-(0.16+0.40*grain))/0.15,0,1)
w=np.clip(0.70*w+0.30*blur(w,2),0,1)

BEARD=np.array([0.062,0.047,0.040],np.float32)
bs=np.clip(base+1.2*det,0.45,1.25)[...,None]
strand=np.clip(0.70+0.44*(n1-0.5)+0.30*(n2-n2.mean()),0.42,1.0)
w=w*strand                                   # let a little skin through
out=out*(1-w[...,None])+np.clip(BEARD[None,None,:]*bs,0,1)*w[...,None]

brow=np.clip((brow-(0.10+0.42*grain))/0.22,0,1)
brow=np.clip(0.75*brow+0.25*blur(brow,2),0,1)*strand
BROWC=np.array([0.062,0.046,0.038],np.float32)
out=out*(1-brow[...,None])+np.clip(BROWC[None,None,:]*bs,0,1)*brow[...,None]

# --------------------------------------------------------- nose shaping
wing = ss(1.30,0.72,np.sqrt(((z-1.6225)/0.0135)**2+((ax-0.0265)/0.0080)**2))*face*ss(-0.050,-0.080,y)
out=out*(1.0-0.20*np.clip(wing,0,1))[...,None]

# ------------------------------------------------------------------- eyes
# build the iris from the eyeball's own geometry: how far a texel's surface
# normal is from looking straight ahead
if ME.any():
    for side in (-1,1):
        m = ME&(np.sign(PE[...,0])==side)
        if not m.any(): continue
        c = np.array([PE[...,k][m].mean() for k in range(3)],np.float32)
        v = PE-c[None,None,:]
        n = np.linalg.norm(v,axis=-1)+1e-9
        fwd=np.array([0.13*side,-1.0,0.0],np.float32); fwd/=np.linalg.norm(fwd)
        cosang=(v@fwd)/n
        ang=np.degrees(np.arccos(np.clip(cosang,-1,1)))
        sclera = m&(ang>27.5)
        limbal = m&(ang<=27.5)&(ang>24.0)
        iris   = m&(ang<=24.0)&(ang>9.5)
        pupil  = m&(ang<=9.5)
        L=np.clip(lum/max(np.percentile(lum[m],70),1e-3),0.25,1.5)[...,None]
        def put(mask,col,lo=0.5,hi=1.2):
            if mask.any():
                k=np.clip(L[mask],lo,hi)
                out[mask]=np.clip(np.array(col,np.float32)[None,:]*k,0,1)
        put(sclera,(0.86,0.845,0.815),0.72,1.10)
        put(limbal,(0.055,0.040,0.032),0.6,1.1)
        put(iris,  (0.150,0.090,0.052),0.45,1.35)
        put(pupil, (0.020,0.016,0.014),0.7,1.1)
        # a little shading where the lids sit
        shadow = m&(ang>27.5)
        out[shadow]*= (0.74+0.26*ss(1.6520,1.6620,PE[...,2]))[shadow][:,None]

Image.fromarray((np.clip(out,0,1)*255).astype(np.uint8)).save(SP+"Thief_Body_diffuse.png")
Image.fromarray((np.clip(out,0,1)*255).astype(np.uint8)).crop((0,0,1024,900)).resize((560,492)).save(SP+"prev_face.png")
print("beard",float((w>0.3).sum()),"brow",float((brow>0.3).sum()),"lips",float((wlip>0.3).sum()),"eye",int(ME.sum()))
