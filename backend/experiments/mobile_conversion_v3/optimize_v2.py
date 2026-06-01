"""Model optimization experiments for the V3 ST-GCN stroke classifier.

Background: static INT8 QDQ quantization (export_v3.py) dropped test top-1 from
89.58% -> 68.69% (-20.89pp) and was rolled back. The app shipped FP32.

This re-opens the optimization with methods that preserve accuracy, so we can
ship a genuinely pruned/quantized model (assignment requires pruning OR
quantization to be APPLIED, not just attempted):

  A) Dynamic INT8 quantization (weights INT8, activations computed in fp at
     runtime) — typically far less lossy than static QDQ for small convnets.
  B) L1 unstructured pruning at several sparsities, on the PyTorch model,
     measured directly (sparse weights -> smaller when compressed).

All measured on the SAME held-out BST test split the model was evaluated on
(loader_v3.load_combined_split('test')). Outputs reports/OPT_RESULTS.json.

Run:  .venv/Scripts/python.exe experiments/mobile_conversion_v3/optimize_v2.py
"""
from __future__ import annotations
import copy
import json
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.utils.prune as prune

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "experiments" / "scorer_baseline"))
sys.path.insert(0, str(ROOT / "experiments" / "stroke_classifier_bst_v3"))
from stgcn import STGCN, count_params  # noqa: E402
from loader_v3 import load_combined_split, POSTER_CLASSES  # noqa: E402

CKPT = ROOT / "experiments" / "stroke_classifier_bst_v3" / "checkpoint.pt"
CONV = ROOT / "experiments" / "mobile_conversion_v3"
FP32_ONNX = CONV / "scorer_v3_fp32.onnx"
OUT_JSON = ROOT / "reports" / "OPT_RESULTS.json"


def load_model():
    m = STGCN(in_channels=3, n_strokes=len(POSTER_CLASSES), n_criteria=1)
    sd = torch.load(CKPT, map_location="cpu")
    m.load_state_dict(sd["state_dict"]); m.eval()
    return m


def metrics(y_true, y_pred):
    acc = float((y_true == y_pred).mean())
    f1s = []
    per = {}
    for ci, cls in enumerate(POSTER_CLASSES):
        tp = int(((y_pred == ci) & (y_true == ci)).sum())
        fp = int(((y_pred == ci) & (y_true != ci)).sum())
        fn = int(((y_pred != ci) & (y_true == ci)).sum())
        prec = tp / (tp + fp) if (tp + fp) else 0.0
        rec = tp / (tp + fn) if (tp + fn) else 0.0
        f1 = 2 * prec * rec / (prec + rec) if (prec + rec) else 0.0
        per[cls] = {"precision": round(prec, 4), "recall": round(rec, 4),
                    "f1": round(f1, 4), "support": int((y_true == ci).sum())}
        f1s.append(f1)
    return round(acc, 4), round(float(np.mean(f1s)), 4), per


def torch_predict(model, X, bs=256):
    preds = []
    with torch.no_grad():
        for i in range(0, len(X), bs):
            xb = torch.from_numpy(X[i:i + bs])
            preds.append(model(xb)["stroke_logits"].argmax(1).numpy())
    return np.concatenate(preds)


def torch_latency(model, X, n_warm=5, n_iter=100):
    x1 = torch.from_numpy(X[:1])
    with torch.no_grad():
        for _ in range(n_warm):
            model(x1)
        t0 = time.perf_counter()
        for _ in range(n_iter):
            model(x1)
    return round((time.perf_counter() - t0) / n_iter * 1000, 3)


def state_dict_nbytes(model):
    return int(sum(p.numel() * p.element_size() for p in model.state_dict().values()
                   if hasattr(p, "numel")))


def nonzero_fraction(model):
    tot = nz = 0
    for _, p in model.named_parameters():
        tot += p.numel(); nz += int((p != 0).sum())
    return nz, tot


def run_dynamic_int8_onnx(X, Y):
    """Weight-only dynamic INT8 on the existing FP32 ONNX graph."""
    from onnxruntime.quantization import quantize_dynamic, QuantType
    import onnxruntime as ort
    out_path = CONV / "scorer_v3_int8_dynamic.onnx"
    quantize_dynamic(FP32_ONNX.as_posix(), out_path.as_posix(),
                     weight_type=QuantType.QInt8)
    sess = ort.InferenceSession(out_path.as_posix(), providers=["CPUExecutionProvider"])
    iname = sess.get_inputs()[0].name
    logits = sess.run(None, {iname: X})[0]
    pred = logits.argmax(1)
    acc, mf1, per = metrics(Y, pred)
    # latency
    for _ in range(5):
        sess.run(None, {iname: X[:1]})
    t0 = time.perf_counter()
    for i in range(100):
        sess.run(None, {iname: X[i % len(X):i % len(X) + 1]})
    lat = round((time.perf_counter() - t0) / 100 * 1000, 3)
    return {"name": "Dynamic INT8 (ONNX, weight-only)",
            "size_kb": round(out_path.stat().st_size / 1024, 1),
            "top1_acc": acc, "macro_f1": mf1, "per_class": per,
            "latency_ms": lat, "path": out_path.name}


def run_pruning(base, X, Y, amounts=(0.3, 0.5, 0.7)):
    """L1 unstructured pruning on Conv2d+Linear weights, no fine-tune (measure
    raw robustness), reported with non-zero fraction (compressible size)."""
    results = []
    for amt in amounts:
        m = copy.deepcopy(base)
        params = [(mod, "weight") for mod in m.modules()
                  if isinstance(mod, (torch.nn.Conv2d, torch.nn.Linear))]
        prune.global_unstructured(params, pruning_method=prune.L1Unstructured, amount=amt)
        for mod, name in params:
            prune.remove(mod, name)
        pred = torch_predict(m, X)
        acc, mf1, per = metrics(Y, pred)
        nz, tot = nonzero_fraction(m)
        results.append({"name": f"Pruned L1 {int(amt*100)}% (no fine-tune)",
                        "sparsity": amt, "nonzero_params": nz, "total_params": tot,
                        "nonzero_fraction": round(nz / tot, 4),
                        "top1_acc": acc, "macro_f1": mf1, "per_class": per,
                        "latency_ms": torch_latency(m, X)})
    return results


def main():
    print("Loading held-out BST test split...")
    X, Y, _ = load_combined_split("test")
    X = X.astype(np.float32)
    counts = {POSTER_CLASSES[c]: int((Y == c).sum()) for c in range(len(POSTER_CLASSES))}
    print(f"  N={len(X)} shape={X.shape} support={counts}")

    base = load_model()
    n_params = count_params(base)
    fp32_pred = torch_predict(base, X)
    acc0, f10, per0 = metrics(Y, fp32_pred)
    fp32 = {"name": "FP32 baseline (PyTorch)", "size_kb": round(state_dict_nbytes(base) / 1024, 1),
            "n_params": n_params, "top1_acc": acc0, "macro_f1": f10,
            "per_class": per0, "latency_ms": torch_latency(base, X)}
    print(f"  FP32 top1={acc0:.4f} f1={f10:.4f} params={n_params}")

    print("[A] dynamic INT8 (ONNX)...")
    dyn = run_dynamic_int8_onnx(X, Y)
    print(f"  dyn INT8 top1={dyn['top1_acc']:.4f} size={dyn['size_kb']}KB")

    print("[B] L1 pruning sweep...")
    pruned = run_pruning(base, X, Y)
    for r in pruned:
        print(f"  {r['name']}: top1={r['top1_acc']:.4f} nonzero={r['nonzero_fraction']}")

    # Reference: prior static INT8 (from results.json), for the comparison story.
    static_ref = None
    rp = CONV / "results.json"
    if rp.exists():
        d = json.loads(rp.read_text())
        static_ref = {"name": "Static INT8 QDQ (rolled back)",
                      "size_kb": round(d["int8_static_qdq"]["size_bytes"] / 1024, 1),
                      "top1_acc": round(d["int8_static_qdq"]["top1_acc"], 4),
                      "note": "calibration-based; activations also quantized"}

    summary = {
        "test_set": {"n": int(len(X)), "support": counts, "classes": POSTER_CLASSES,
                     "split": "BST ShuttleSet_25c + BadmintonDB held-out test"},
        "fp32_baseline": fp32,
        "dynamic_int8": dyn,
        "static_int8_rolled_back": static_ref,
        "pruning": pruned,
        "deltas_vs_fp32": {
            "dynamic_int8_acc_pp": round((dyn["top1_acc"] - acc0) * 100, 2),
            "dynamic_int8_size_ratio": round(fp32["size_kb"] / dyn["size_kb"], 2),
        },
    }
    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")

    print("\n" + "=" * 72)
    print("OPTIMIZATION RESULTS (test set, vs FP32 89.58%)")
    print("=" * 72)
    print(f"{'method':<38}{'KB':>8}{'top1':>9}{'ms':>8}")
    print("-" * 72)
    rows = [fp32, dyn] + pruned
    if static_ref:
        rows.append({**static_ref, "macro_f1": None, "latency_ms": None})
    for r in rows:
        kb = r.get("size_kb"); kb = f"{kb}" if kb else "-"
        ms = r.get("latency_ms"); ms = f"{ms}" if ms else "-"
        print(f"{r['name']:<38}{kb:>8}{r['top1_acc']*100:>8.2f}%{ms:>8}")
    print("=" * 72)
    print(f"JSON -> {OUT_JSON}")


if __name__ == "__main__":
    main()
