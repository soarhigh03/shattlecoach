"""Diagnose + fix the BST->phone domain gap WITHOUT retraining first.

Root cause (measured): BST training clips have confidence channel == 1.0 always,
but MoveNet gives real confidences (0.02-0.9). The model never saw conf<1, so
real clips are out-of-distribution. Also MoveNet emits coordinate outliers
(y up to 15.5 after normalization) that corrupt the hip-centered scaling.

This script re-extracts donghwi clips raw and tests preprocessing fixes against
the FROZEN current model (no retrain), to see how much accuracy preprocessing
alone recovers:
  fix A: force conf=1.0 (match BST)
  fix B: confidence-gated normalization + outlier clip
  fix C: A+B combined

Then reports which preprocessing the app should adopt.
"""
from __future__ import annotations
import json
import sys
from pathlib import Path
import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "experiments" / "scorer_baseline"))
sys.path.insert(0, str(ROOT / "experiments" / "stroke_classifier_bst_v3"))
from stgcn import STGCN  # noqa
from loader_v3 import POSTER_CLASSES, T_TARGET  # noqa

CKPT = ROOT / "experiments" / "stroke_classifier_bst_v3" / "checkpoint.pt"
CLIPS = ROOT / "data" / "donghwi_clips"
SPLIT = CLIPS / "split.json"
MOVENET = ROOT / "flutter_app" / "assets" / "movenet_lightning_int8.tflite"
RAW_CACHE = ROOT / "experiments" / "stroke_classifier_user" / "donghwi_raw_kpts.npz"

COCO_17 = ["nose","left_eye","right_eye","left_ear","right_ear","left_shoulder",
           "right_shoulder","left_elbow","right_elbow","left_wrist","right_wrist",
           "left_hip","right_hip","left_knee","right_knee","left_ankle","right_ankle"]
IDX = {n: i for i, n in enumerate(COCO_17)}


def extract_raw(video_path, interp):
    import cv2
    ind = interp.get_input_details()[0]; outd = interp.get_output_details()[0]
    size = ind["shape"][1]; dt = ind["dtype"]
    cap = cv2.VideoCapture(str(video_path))
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)); h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    out = []
    while True:
        ok, fr = cap.read()
        if not ok: break
        import cv2 as _c
        rgb = _c.cvtColor(fr, _c.COLOR_BGR2RGB)
        r = _c.resize(rgb, (size, size))
        inp = r.astype(np.uint8)[None] if dt == np.uint8 else (r.astype(np.float32)/255)[None]
        interp.set_tensor(ind["index"], inp); interp.invoke()
        o = interp.get_tensor(outd["index"])[0,0]
        kp = np.zeros((17,3), np.float32)
        kp[:,0]=o[:,1]*w; kp[:,1]=o[:,0]*h; kp[:,2]=o[:,2]
        out.append(kp)
    cap.release()
    return np.stack(out,0) if out else np.zeros((0,17,3),np.float32)


def get_raw_clips():
    if RAW_CACHE.exists():
        d = np.load(RAW_CACHE, allow_pickle=True)
        return list(d["clips"]), d["labels"]
    import tensorflow as tf
    interp = tf.lite.Interpreter(model_path=str(MOVENET)); interp.allocate_tensors()
    split = json.loads(SPLIT.read_text(encoding="utf-8"))
    clips, labels = [], []
    for group in ("dev","test"):
        for cls, files in split[group].items():
            ci = POSTER_CLASSES.index(cls)
            for fn in files:
                kp = extract_raw(CLIPS/fn, interp)
                if kp.shape[0] >= 2:
                    clips.append(kp); labels.append(ci)
    np.savez(RAW_CACHE, clips=np.array(clips,dtype=object), labels=np.array(labels))
    return clips, np.array(labels)


def preprocess(kp, force_conf=False, conf_gate=False, clip_outlier=False, t_out=T_TARGET):
    """kp: (T,17,3) raw pixel coords. Returns (3,T,17)."""
    k = kp.copy().astype(np.float32)
    T = k.shape[0]
    for i in range(T):
        conf = k[i,:,2]
        if conf_gate:
            # use only confident joints to compute center/scale
            valid = conf > 0.2
            hips = [IDX["left_hip"], IDX["right_hip"]]
            sh = [IDX["left_shoulder"], IDX["right_shoulder"]]
            hv = [j for j in hips if conf[j] > 0.2] or hips
            sv = [j for j in sh if conf[j] > 0.2] or sh
            mh = k[i, hv, :2].mean(0); ms = k[i, sv, :2].mean(0)
        else:
            mh = (k[i,IDX["left_hip"],:2]+k[i,IDX["right_hip"],:2])/2
            ms = (k[i,IDX["left_shoulder"],:2]+k[i,IDX["right_shoulder"],:2])/2
        scale = float(np.sqrt(((ms-mh)**2).sum()))+1e-6
        k[i,:,0]=(k[i,:,0]-mh[0])/scale
        k[i,:,1]=(k[i,:,1]-mh[1])/scale
    if clip_outlier:
        k[:,:,0]=np.clip(k[:,:,0],-3,3); k[:,:,1]=np.clip(k[:,:,1],-3,3)
    if force_conf:
        k[:,:,2]=1.0
    # resample T
    if T != t_out:
        src=np.linspace(0,1,T); dst=np.linspace(0,1,t_out)
        r=np.empty((t_out,17,3),np.float32)
        for j in range(17):
            for c in range(3):
                r[:,j,c]=np.interp(dst,src,k[:,j,c])
        k=r
    return np.transpose(k,(2,0,1)).astype(np.float32)


def load_model():
    m=STGCN(in_channels=3,n_strokes=3,n_criteria=1)
    m.load_state_dict(torch.load(CKPT,map_location="cpu")["state_dict"]); m.eval()
    return m


def evalp(model, clips, labels, **kw):
    X=np.stack([preprocess(c,**kw) for c in clips],0)
    with torch.no_grad():
        p=model(torch.from_numpy(X))["stroke_logits"].argmax(1).numpy()
    acc=float((p==labels).mean())
    pc={POSTER_CLASSES[ci]:round(float((p[labels==ci]==ci).mean()),3) if (labels==ci).any() else None
        for ci in range(3)}
    return acc, pc, p


def main():
    clips, labels = get_raw_clips()
    print(f"clips={len(clips)} labels={np.bincount(labels,minlength=3).tolist()}")
    m=load_model()
    configs={
      "baseline (current app preproc)": {},
      "A: force conf=1.0": {"force_conf":True},
      "B: conf-gate + clip outliers": {"conf_gate":True,"clip_outlier":True},
      "C: A+B (gate+clip+conf1)": {"force_conf":True,"conf_gate":True,"clip_outlier":True},
    }
    out={}
    for name,kw in configs.items():
        acc,pc,_=evalp(m,clips,labels,**kw)
        out[name]={"acc":round(acc,4),"per_class":pc}
        print(f"{name:34s} acc={acc:.4f} per_class={pc}")
    (ROOT/"reports"/"PREPROCESS_FIX.json").write_text(json.dumps(out,indent=2,ensure_ascii=False),encoding="utf-8")
    print("\nJSON -> reports/PREPROCESS_FIX.json")


if __name__=="__main__":
    main()
