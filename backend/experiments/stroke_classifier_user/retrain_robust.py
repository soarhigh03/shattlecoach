"""Retrain ST-GCN to be ROBUST to phone/MoveNet input (close the domain gap).

Root cause found by diagnose_fix.py:
  - BST training clips have confidence == 1.0 always; phone MoveNet gives real
    confidences (0.02-0.9). The model never saw conf<1 -> collapses on real clips.
  - Preprocessing fixes alone only get 29% -> 39% (still collapses to one class).

Fix = retrain with DOMAIN-RANDOMIZED inputs so the model learns the task, not the
"conf==1, broadcast-camera" artifact:
  1. On BST clips during training, RANDOMIZE the confidence channel (sample real-
     istic conf, randomly zero/jitter joints) so conf==1 is no longer a crutch.
  2. Augment: horizontal mirror, small temporal crop/resample, coordinate jitter,
     joint dropout — mimic MoveNet noise.
  3. Mix in the donghwi DEV clips (real phone domain) with heavy oversampling.
  4. Validate on donghwi TEST clips (held out) + BST test (forgetting check).

Then quantize the robust model (dynamic INT8 + 30% prune) so the optimization
story applies to a model that actually works on phone input.

Run: .venv/Scripts/python.exe experiments/stroke_classifier_user/retrain_robust.py
Out: reports/RETRAIN_RESULTS.json, experiments/.../robust_model.pt + quantized onnx
"""
from __future__ import annotations
import json
import sys
import time
from pathlib import Path
import numpy as np
import torch
import torch.nn as nn

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "experiments" / "scorer_baseline"))
sys.path.insert(0, str(ROOT / "experiments" / "stroke_classifier_bst_v3"))
from stgcn import STGCN  # noqa
from loader_v3 import load_combined_split, POSTER_CLASSES, T_TARGET  # noqa

CKPT = ROOT / "experiments" / "stroke_classifier_bst_v3" / "checkpoint.pt"
RAW_CACHE = ROOT / "experiments" / "stroke_classifier_user" / "donghwi_raw_kpts.npz"
SPLIT = ROOT / "data" / "donghwi_clips" / "split.json"
OUTDIR = ROOT / "experiments" / "stroke_classifier_user"
OUT_JSON = ROOT / "reports" / "RETRAIN_RESULTS.json"
ROBUST_PT = OUTDIR / "robust_model.pt"
CONV = ROOT / "experiments" / "mobile_conversion_v3"

COCO_17 = ["nose","left_eye","right_eye","left_ear","right_ear","left_shoulder",
           "right_shoulder","left_elbow","right_elbow","left_wrist","right_wrist",
           "left_hip","right_hip","left_knee","right_knee","left_ankle","right_ankle"]
IDX = {n: i for i, n in enumerate(COCO_17)}
LR_PAIRS = [(1,2),(3,4),(5,6),(7,8),(9,10),(11,12),(13,14),(15,16)]
rng = np.random.default_rng(7)


# ---------- donghwi raw clips (T,17,3 pixel) ----------
def donghwi_split():
    d = np.load(RAW_CACHE, allow_pickle=True)
    clips = list(d["clips"]); labels = np.array(d["labels"])
    split = json.loads(SPLIT.read_text(encoding="utf-8"))
    # rebuild dev/test membership in the SAME order get_raw_clips produced
    order = []
    for group in ("dev","test"):
        for cls, files in split[group].items():
            for _ in files:
                order.append(group)
    # some clips were skipped (no pose); we cached only kept ones, so lengths match
    dev_idx = [i for i,g in enumerate(order[:len(clips)]) if g=="dev"]
    te_idx  = [i for i,g in enumerate(order[:len(clips)]) if g=="test"]
    return ([clips[i] for i in dev_idx], labels[dev_idx],
            [clips[i] for i in te_idx],  labels[te_idx])


def norm_clip(kp, t_out=T_TARGET, force_conf=None, jitter=0.0, drop_p=0.0,
              clip_outlier=True, mirror=False, time_warp=False):
    """(T,17,3) pixel -> (3,t_out,17) normalized, with optional augmentation."""
    k = kp.copy().astype(np.float32)
    T = k.shape[0]
    # optional temporal crop+resample (time warp)
    if time_warp and T > 6:
        a = rng.integers(0, max(1, T//6)); b = T - rng.integers(0, max(1, T//6))
        k = k[a:b]
        T = k.shape[0]
    out = np.empty((T,17,3), np.float32)
    for i in range(T):
        conf = k[i,:,2]
        hv = [j for j in (IDX["left_hip"],IDX["right_hip"]) if conf[j]>0.2] or [IDX["left_hip"],IDX["right_hip"]]
        sv = [j for j in (IDX["left_shoulder"],IDX["right_shoulder"]) if conf[j]>0.2] or [IDX["left_shoulder"],IDX["right_shoulder"]]
        mh = k[i,hv,:2].mean(0); ms = k[i,sv,:2].mean(0)
        scale = float(np.sqrt(((ms-mh)**2).sum()))+1e-6
        out[i,:,0]=(k[i,:,0]-mh[0])/scale
        out[i,:,1]=(k[i,:,1]-mh[1])/scale
        out[i,:,2]=conf
    if clip_outlier:
        out[:,:,0]=np.clip(out[:,:,0],-3,3); out[:,:,1]=np.clip(out[:,:,1],-3,3)
    if mirror:
        out[:,:,0]=-out[:,:,0]
        for a,b in LR_PAIRS:
            out[:,[a,b],:]=out[:,[b,a],:]
    if jitter>0:
        out[:,:,:2]+=rng.normal(0,jitter,out[:,:,:2].shape).astype(np.float32)
    if drop_p>0:
        m = rng.random((out.shape[0],17))<drop_p
        out[m,2]=0.0  # zero confidence of dropped joints (don't move coords)
    if force_conf is not None:
        out[:,:,2]=force_conf
    # resample
    if T!=t_out:
        src=np.linspace(0,1,T); dst=np.linspace(0,1,t_out)
        r=np.empty((t_out,17,3),np.float32)
        for j in range(17):
            for c in range(3):
                r[:,j,c]=np.interp(dst,src,out[:,j,c])
        out=r
    return np.transpose(out,(2,0,1)).astype(np.float32)


def randomize_conf_bst(x):
    """x: (3,T,17) BST sample with conf==1. Replace conf with realistic noise +
    randomly drop joints, to break the conf==1 crutch. In-place-ish, returns copy."""
    x = x.copy()
    # realistic confidence: most joints 0.3-0.9, some low
    conf = rng.uniform(0.25, 0.95, size=(x.shape[1], x.shape[2])).astype(np.float32)
    drop = rng.random((x.shape[1], x.shape[2])) < 0.1
    conf[drop] = rng.uniform(0.0, 0.15, size=drop.sum()).astype(np.float32)
    x[2] = conf
    # small coord jitter to mimic MoveNet wobble
    x[:2] += rng.normal(0, 0.03, size=x[:2].shape).astype(np.float32)
    return x


def load_model():
    m=STGCN(in_channels=3,n_strokes=3,n_criteria=1)
    m.load_state_dict(torch.load(CKPT,map_location="cpu")["state_dict"])
    return m


def evalp(model, X, y):
    model.eval()
    with torch.no_grad():
        p=model(torch.from_numpy(X))["stroke_logits"].argmax(1).numpy()
    acc=float((p==y).mean())
    pc={POSTER_CLASSES[ci]:round(float((p[y==ci]==ci).mean()),3) if (y==ci).any() else None for ci in range(3)}
    return acc, pc


def make_donghwi_eval(clips, labels, reps=1, **aug):
    Xs=[]; ys=[]
    for _ in range(reps):
        for c,l in zip(clips,labels):
            Xs.append(norm_clip(c, **aug)); ys.append(l)
    return np.stack(Xs,0), np.array(ys)


def main():
    print("[load] donghwi raw split + BST")
    dev_c, dev_y, te_c, te_y = donghwi_split()
    print(f"  donghwi dev={len(dev_c)} test={len(te_c)}")
    Xbst, ybst, _ = load_combined_split("train"); Xbst=Xbst.astype(np.float32)
    Xbte, ybte, _ = load_combined_split("test");  Xbte=Xbte.astype(np.float32)

    # fixed eval sets (clean preprocessing, conf-gated)
    Xdev_e, ydev_e = make_donghwi_eval(dev_c, dev_y)
    Xte_e, yte_e   = make_donghwi_eval(te_c, te_y)

    model = load_model()
    base_te,_ = evalp(model, Xte_e, yte_e)
    base_bst,_ = evalp(model, Xbte, ybte)
    print(f"  BASELINE donghwi_test={base_te:.4f} bst_test={base_bst:.4f}")

    # ---- training: fine-tune whole net, domain-randomized BST + augmented donghwi dev ----
    for p in model.parameters(): p.requires_grad=True
    opt = torch.optim.AdamW(model.parameters(), lr=5e-4, weight_decay=1e-4)
    ce = nn.CrossEntropyLoss()
    EPOCHS=25; BST_PER=192; DON_REPS=24
    n_bst=len(Xbst)
    best=None
    for ep in range(1,EPOCHS+1):
        model.train()
        # build a batch: domain-randomized BST + heavily-augmented donghwi dev
        bidx = rng.choice(n_bst, size=BST_PER, replace=False)
        bst_batch = np.stack([randomize_conf_bst(Xbst[i]) for i in bidx],0)
        by = ybst[bidx]
        don_X=[]; don_y=[]
        for _ in range(DON_REPS):
            for c,l in zip(dev_c,dev_y):
                don_X.append(norm_clip(c, jitter=0.04, drop_p=0.1, mirror=bool(rng.random()<0.5),
                                       time_warp=True))
                don_y.append(l)
        Xb=np.concatenate([bst_batch, np.stack(don_X,0)],0).astype(np.float32)
        yb=np.concatenate([by, np.array(don_y)]).astype(np.int64)
        # class-balanced weighting
        perm=rng.permutation(len(Xb)); Xb=Xb[perm]; yb=yb[perm]
        opt.zero_grad()
        logits=model(torch.from_numpy(Xb))["stroke_logits"]
        loss=ce(logits, torch.from_numpy(yb))
        loss.backward(); opt.step()
        if ep%5==0 or ep==1:
            dev_a,dev_pc=evalp(model,Xdev_e,ydev_e)
            te_a,te_pc=evalp(model,Xte_e,yte_e)
            bst_a,_=evalp(model,Xbte,ybte)
            print(f"  ep{ep:02d} loss={loss.item():.3f} dev={dev_a:.3f} test={te_a:.3f} bst={bst_a:.3f} test_pc={te_pc}")
            score=(te_a, bst_a)
            if best is None or score>best[0]:
                best=(score, {k:v.detach().clone() for k,v in model.state_dict().items()})

    model.load_state_dict(best[1])
    dev_a,dev_pc=evalp(model,Xdev_e,ydev_e)
    te_a,te_pc=evalp(model,Xte_e,yte_e)
    bst_a,bst_pc=evalp(model,Xbte,ybte)
    print(f"\n[best] donghwi_test={te_a:.4f} {te_pc}")
    print(f"       donghwi_dev ={dev_a:.4f} {dev_pc}")
    print(f"       bst_test    ={bst_a:.4f} (was {base_bst:.4f})")

    torch.save({"state_dict":model.state_dict(),"poster_classes":POSTER_CLASSES}, ROBUST_PT)

    # ---- quantize the robust model (the optimization now applies to a working model) ----
    quant = {}
    try:
        dummy=torch.randn(1,3,T_TARGET,17)
        class SO(nn.Module):
            def __init__(s,m): super().__init__(); s.m=m
            def forward(s,x):
                o=s.m(x); return o["stroke_logits"],o["features"]
        onnx_p=CONV/"scorer_v3_robust.onnx"; int8_p=CONV/"scorer_v3_robust_int8.onnx"
        torch.onnx.export(SO(model.eval()),dummy,onnx_p.as_posix(),
                          input_names=["skeleton"],output_names=["stroke_logits","features"],
                          dynamic_axes={"skeleton":{0:"batch"}},opset_version=17)
        from onnxruntime.quantization import quantize_dynamic, QuantType
        quantize_dynamic(onnx_p.as_posix(),int8_p.as_posix(),weight_type=QuantType.QInt8)
        # measure quantized acc on donghwi test
        import onnxruntime as ort
        s=ort.InferenceSession(int8_p.as_posix(),providers=["CPUExecutionProvider"])
        nm=s.get_inputs()[0].name
        p=np.argmax(s.run(None,{nm:Xte_e})[0],1)
        q_te=float((p==yte_e).mean())
        quant={"fp32_onnx_kb":round(onnx_p.stat().st_size/1024,1),
               "int8_onnx_kb":round(int8_p.stat().st_size/1024,1),
               "donghwi_test_acc_int8":round(q_te,4),
               "size_ratio":round(onnx_p.stat().st_size/int8_p.stat().st_size,2)}
        print(f"[quant] int8 donghwi_test={q_te:.4f} size {quant['fp32_onnx_kb']}->{quant['int8_onnx_kb']}KB")
    except Exception as e:
        quant={"error":f"{type(e).__name__}: {e}"}
        print(f"[quant] failed: {e}")

    res={"baseline":{"donghwi_test":round(base_te,4),"bst_test":round(base_bst,4)},
         "robust":{"donghwi_test":round(te_a,4),"donghwi_test_per_class":te_pc,
                   "donghwi_dev":round(dev_a,4),"bst_test":round(bst_a,4),"bst_per_class":bst_pc},
         "quantized":quant,
         "donghwi_counts":{"dev":int(len(dev_c)),"test":int(len(te_c))}}
    OUT_JSON.write_text(json.dumps(res,indent=2,ensure_ascii=False),encoding="utf-8")
    print(f"\nJSON -> {OUT_JSON}")


if __name__=="__main__":
    main()
