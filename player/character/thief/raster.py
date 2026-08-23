import numpy as np, sys
from PIL import Image

SP="/tmp/claude-1000/-home-talves-mthings-LandsOfBalance/749a8653-c369-44b9-b617-9c464a65ee06/scratchpad/"
d=np.load(SP+"meshdata.npz")

def posmap(name, size=1024):
    co=d[name+"_co"]; uv=d[name+"_uv"]; tl=d[name+"_tl"]; tv=d[name+"_tv"]
    P=np.zeros((size,size,3), np.float32)
    M=np.zeros((size,size), np.uint8)
    # per triangle rasterize in UV space
    tuv = uv[tl]            # (nt,3,2)
    tco = co[tv]            # (nt,3,3)
    px = tuv[:,:,0]*size
    py = (1.0-tuv[:,:,1])*size
    for i in range(len(tl)):
        x0,x1,x2 = px[i]; y0,y1,y2 = py[i]
        xmin=int(max(0,np.floor(min(x0,x1,x2))-1)); xmax=int(min(size-1,np.ceil(max(x0,x1,x2))+1))
        ymin=int(max(0,np.floor(min(y0,y1,y2))-1)); ymax=int(min(size-1,np.ceil(max(y0,y1,y2))+1))
        if xmax<xmin or ymax<ymin: continue
        xs=np.arange(xmin,xmax+1)+0.5; ys=np.arange(ymin,ymax+1)+0.5
        X,Y=np.meshgrid(xs,ys)
        den=((y1-y2)*(x0-x2)+(x2-x1)*(y0-y2))
        if abs(den)<1e-12: continue
        a=((y1-y2)*(X-x2)+(x2-x1)*(Y-y2))/den
        b=((y2-y0)*(X-x2)+(x0-x2)*(Y-y2))/den
        c=1.0-a-b
        m=(a>=-0.02)&(b>=-0.02)&(c>=-0.02)
        if not m.any(): continue
        pos = a[...,None]*tco[i,0] + b[...,None]*tco[i,1] + c[...,None]*tco[i,2]
        sub=P[ymin:ymax+1, xmin:xmax+1]
        subm=M[ymin:ymax+1, xmin:xmax+1]
        sub[m]=pos[m]; subm[m]=1
    return P,M

if __name__=="__main__":
    for name in ("Thief_Clothes","Thief_Body"):
        P,M=posmap(name, 1024)
        np.savez_compressed(SP+name+"_pos.npz", P=P, M=M)
        # visualize height
        z=P[:,:,2]; x=P[:,:,0]; y=P[:,:,1]
        vis=np.zeros((1024,1024,3),np.uint8)
        vis[:,:,0]=np.clip((x+0.95)/1.9*255,0,255).astype(np.uint8)
        vis[:,:,1]=np.clip(z/1.85*255,0,255).astype(np.uint8)
        vis[:,:,2]=np.clip((y+0.3)/0.6*255,0,255).astype(np.uint8)
        vis[M==0]=0
        Image.fromarray(vis).save(SP+name+"_posvis.png")
        print(name, "coverage", M.mean())
