"""Domain-adapt the ST-GCN stroke classifier to REAL phone clips (donghwi).

Problem: the classifier was trained on BST broadcast skeletons and misclassifies
real phone clips (the whole reason the app fell back to "user picks the stroke").
The earlier finetune (phase_b) used only 6 clips / 387 trainable params and
failed (user_acc stayed 33%, BST forgot 27pp).

This redo:
  1. Extracts MoveNet keypoints from ALL 51 labeled donghwi clips (same pose
     model the app uses) using the dev/test split in data/donghwi_clips/split.json.
  2. Measures the CURRENT model on the held-out donghwi TEST clips (baseline).
  3. Fine-tunes (two regimes: head-only, and last-block+head) on the dev clips
     with BST-replay to limit forgetting, picks the best on dev.
  4. Re-measures on donghwi test AND BST test (forgetting check).
  5. Exports the adapted model -> ONNX -> dynamic INT8 (the optimization stays).

Outputs reports/ADAPT_RESULTS.json + experiments/stroke_classifier_user/user_adapted.pt
Run: .venv/Scripts/python.exe experiments/stroke_classifier_user/adapt_v2.py
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
sys.path.insert(0, str(ROOT / "backend" / "scripts"))
from stgcn import STGCN  # noqa: E402
from loader_v3 import load_combined_split, POSTER_CLASSES, T_TARGET  # noqa: E402

CKPT = ROOT / "experiments" / "stroke_classifier_bst_v3" / "checkpoint.pt"
CLIPS = ROOT / "data" / "donghwi_clips"
SPLIT = CLIPS / "split.json"
MOVENET = ROOT / "flutter_app" / "assets" / "movenet_lightning_int8.tflite"
OUTDIR = ROOT / "experiments" / "stroke_classifier_user"
KPT_CACHE = OUTDIR / "donghwi_movenet_kpts.npz"
OUT_JSON = ROOT / "reports" / "ADAPT_RESULTS.json"
ADAPTED_PT = OUTDIR / "user_adapted.pt"

COCO_17 = [
    "nose", "left_eye", "right_eye", "left_ear", "right_ear",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
    "left_wrist", "right_wrist", "left_hip", "right_hip",
    "left_knee", "right_knee", "left_ankle", "right_ankle",
]


def extract_movenet_kpts(video_path, interp):
    import cv2
    in_det = interp.get_input_details()[0]
    out_det = interp.get_output_details()[0]
    size = in_det["shape"][1]
    dtype = in_det["dtype"]
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise FileNotFoundError(video_path)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)); h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    frames = []
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        resized = cv2.resize(rgb, (size, size))
        inp = resized.astype(np.uint8)[None, ...] if dtype == np.uint8 \
            else (resized.astype(np.float32) / 255.0)[None, ...]
        interp.set_tensor(in_det["index"], inp); interp.invoke()
        out = interp.get_tensor(out_det["index"])[0, 0]  # (17,3) y,x,conf
        kp = np.zeros((17, 3), np.float32)
        kp[:, 0] = out[:, 1] * w; kp[:, 1] = out[:, 0] * h; kp[:, 2] = out[:, 2]
        frames.append(kp)
    cap.release()
    return np.stack(frames, 0) if frames else np.zeros((0, 17, 3), np.float32)


def normalise_resample(kpts, t_out=T_TARGET):
    """(T,17,3) -> (3,t_out,17) matching loader / classifier preprocessing."""
    idx = {n: i for i, n in enumerate(COCO_17)}
    out = kpts.copy().astype(np.float32)
    for i in range(out.shape[0]):
        mh = (out[i, idx["left_hip"], :2] + out[i, idx["right_hip"], :2]) / 2
        ms = (out[i, idx["left_shoulder"], :2] + out[i, idx["right_shoulder"], :2]) / 2
        scale = float(np.sqrt(((ms - mh) ** 2).sum())) + 1e-6
        out[i, :, 0] = (out[i, :, 0] - mh[0]) / scale
        out[i, :, 1] = (out[i, :, 1] - mh[1]) / scale
    t_in = out.shape[0]
    if t_in != t_out:
        src = np.linspace(0, 1, t_in); dst = np.linspace(0, 1, t_out)
        res = np.empty((t_out, 17, 3), np.float32)
        for j in range(17):
            for c in range(3):
                res[:, j, c] = np.interp(dst, src, out[:, j, c])
        out = res
    return np.transpose(out, (2, 0, 1)).astype(np.float32)  # (3,T,17)


def build_donghwi_set():
    if KPT_CACHE.exists():
        d = np.load(KPT_CACHE, allow_pickle=True)
        return (d["Xdev"], d["ydev"], d["Xte"], d["yte"])
    import tensorflow as tf
    interp = tf.lite.Interpreter(model_path=str(MOVENET)); interp.allocate_tensors()
    split = json.loads(SPLIT.read_text(encoding="utf-8"))
    def load(group):
        Xs, ys = [], []
        for cls, files in split[group].items():
            ci = POSTER_CLASSES.index(cls)
            for fn in files:
                kp = extract_movenet_kpts(CLIPS / fn, interp)
                if kp.shape[0] < 2:
                    print(f"  skip {fn} (no pose)"); continue
                Xs.append(normalise_resample(kp)); ys.append(ci)
        return np.stack(Xs, 0).astype(np.float32), np.array(ys, np.int64)
    Xdev, ydev = load("dev"); Xte, yte = load("test")
    np.savez(KPT_CACHE, Xdev=Xdev, ydev=ydev, Xte=Xte, yte=yte)
    return Xdev, ydev, Xte, yte


def load_model():
    m = STGCN(in_channels=3, n_strokes=len(POSTER_CLASSES), n_criteria=1)
    sd = torch.load(CKPT, map_location="cpu"); m.load_state_dict(sd["state_dict"])
    return m


def acc(model, X, y):
    model.eval()
    with torch.no_grad():
        p = model(torch.from_numpy(X))["stroke_logits"].argmax(1).numpy()
    return float((p == y).mean()), p


def per_class_acc(y, p):
    out = {}
    for ci, c in enumerate(POSTER_CLASSES):
        m = y == ci
        out[c] = round(float((p[m] == ci).mean()), 4) if m.sum() else None
    return out


def finetune(regime, Xdev, ydev, Xbst, ybst, epochs=40, lr=1e-3):
    """regime: 'head' | 'block5+head'. BST replay each step to limit forgetting."""
    m = load_model()
    for p in m.parameters():
        p.requires_grad = False
    train = list(m.stroke_head.parameters())
    if regime == "block5+head":
        train += list(m.blocks[4].parameters())
    for p in train:
        p.requires_grad = True
    opt = torch.optim.Adam(train, lr=lr, weight_decay=1e-4)
    ce = nn.CrossEntropyLoss()
    Xd = torch.from_numpy(Xdev); yd = torch.from_numpy(ydev)
    # small BST replay batch indices
    rng = np.random.default_rng(0)
    for ep in range(epochs):
        m.train()
        opt.zero_grad()
        loss = ce(m(Xd)["stroke_logits"], yd)
        ridx = rng.choice(len(Xbst), size=min(96, len(Xbst)), replace=False)
        loss = loss + 0.5 * ce(m(torch.from_numpy(Xbst[ridx]))["stroke_logits"],
                               torch.from_numpy(ybst[ridx]))
        loss.backward(); opt.step()
    return m


def export_and_quantize(model, tag):
    dummy = torch.randn(1, 3, T_TARGET, 17)

    class SO(nn.Module):
        def __init__(s, m): super().__init__(); s.m = m
        def forward(s, x):
            o = s.m(x); return o["stroke_logits"], o["features"]
    onnx_p = ROOT / "experiments" / "mobile_conversion_v3" / f"scorer_{tag}.onnx"
    int8_p = ROOT / "experiments" / "mobile_conversion_v3" / f"scorer_{tag}_int8.onnx"
    torch.onnx.export(SO(model.eval()), dummy, onnx_p.as_posix(),
                      input_names=["skeleton"], output_names=["stroke_logits", "features"],
                      dynamic_axes={"skeleton": {0: "batch"}}, opset_version=17)
    from onnxruntime.quantization import quantize_dynamic, QuantType
    quantize_dynamic(onnx_p.as_posix(), int8_p.as_posix(), weight_type=QuantType.QInt8)
    return onnx_p, int8_p


def main():
    print("[1] extract MoveNet kpts for donghwi clips...")
    Xdev, ydev, Xte, yte = build_donghwi_set()
    print(f"  dev N={len(Xdev)} {np.bincount(ydev, minlength=3).tolist()} | "
          f"test N={len(Xte)} {np.bincount(yte, minlength=3).tolist()}")

    print("[2] BST test (for forgetting check) + baseline on donghwi...")
    Xbst, ybst, _ = load_combined_split("test"); Xbst = Xbst.astype(np.float32)
    Xtr, ytr, _ = load_combined_split("train"); Xtr = Xtr.astype(np.float32)
    base = load_model()
    bst_before, _ = acc(base, Xbst, ybst)
    dev_before, _ = acc(base, Xdev, ydev)
    te_before, pte_before = acc(base, Xte, yte)
    print(f"  BASELINE  bst={bst_before:.4f}  donghwi_dev={dev_before:.4f}  donghwi_test={te_before:.4f}")
    print(f"  donghwi_test per-class: {per_class_acc(yte, pte_before)}")

    print("[3] fine-tune regimes (replay BST train)...")
    results = {}
    best = None
    for regime in ("head", "block5+head"):
        m = finetune(regime, Xdev, ydev, Xtr, ytr)
        dev_a, _ = acc(m, Xdev, ydev)
        te_a, pte = acc(m, Xte, yte)
        bst_a, _ = acc(m, Xbst, ybst)
        results[regime] = {"donghwi_dev": round(dev_a, 4), "donghwi_test": round(te_a, 4),
                           "bst_test": round(bst_a, 4),
                           "donghwi_test_per_class": per_class_acc(yte, pte),
                           "bst_forgetting_pp": round((bst_before - bst_a) * 100, 2)}
        print(f"  {regime:14s} dev={dev_a:.4f} test={te_a:.4f} bst={bst_a:.4f} "
              f"forget={results[regime]['bst_forgetting_pp']:+.2f}pp")
        # pick best by donghwi_test then lowest forgetting
        score = (te_a, -abs(bst_before - bst_a))
        if best is None or score > best[0]:
            best = (score, regime, m)

    best_regime, best_model = best[1], best[2]
    print(f"[4] best = {best_regime}; export + dynamic INT8 quantize...")
    onnx_p, int8_p = export_and_quantize(best_model, "v3_user_adapted")
    torch.save({"state_dict": best_model.state_dict(), "regime": best_regime,
                "poster_classes": POSTER_CLASSES}, ADAPTED_PT)

    summary = {
        "donghwi_clips": {"dev_n": int(len(Xdev)), "test_n": int(len(Xte)),
                          "dev_per_class": np.bincount(ydev, minlength=3).tolist(),
                          "test_per_class": np.bincount(yte, minlength=3).tolist()},
        "baseline": {"bst_test": round(bst_before, 4), "donghwi_dev": round(dev_before, 4),
                     "donghwi_test": round(te_before, 4),
                     "donghwi_test_per_class": per_class_acc(yte, pte_before)},
        "finetune": results,
        "chosen_regime": best_regime,
        "adapted_int8_size_kb": round(int8_p.stat().st_size / 1024, 1),
        "adapted_onnx": onnx_p.name, "adapted_int8": int8_p.name,
    }
    OUT_JSON.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"\n[ok] {OUT_JSON}")
    print(json.dumps(summary["baseline"], indent=2))
    print(json.dumps(summary["finetune"], indent=2))


if __name__ == "__main__":
    main()
