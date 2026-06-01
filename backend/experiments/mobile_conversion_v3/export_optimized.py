"""Produce the FINAL optimized classifier: L1 prune 30% -> ONNX -> dynamic INT8.

This is the model we actually ship for the on-device stroke-confirmation check.
Combines BOTH optimizations the assignment asks for (pruning AND quantization),
and we verify the combined model still holds accuracy on the held-out test set.

Outputs:
  scorer_v3_pruned30.onnx          (FP32 ONNX of the 30%-pruned model)
  scorer_v3_pruned30_int8.onnx     (dynamic INT8 of the pruned model)  <- SHIP
  reports/OPT_FINAL.json
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
from loader_v3 import load_combined_split, POSTER_CLASSES, T_TARGET  # noqa: E402

CKPT = ROOT / "experiments" / "stroke_classifier_bst_v3" / "checkpoint.pt"
CONV = ROOT / "experiments" / "mobile_conversion_v3"
PRUNED_ONNX = CONV / "scorer_v3_pruned30.onnx"
PRUNED_INT8 = CONV / "scorer_v3_pruned30_int8.onnx"
OUT_JSON = ROOT / "reports" / "OPT_FINAL.json"
PRUNE_AMOUNT = 0.30


def load_model():
    m = STGCN(in_channels=3, n_strokes=len(POSTER_CLASSES), n_criteria=1)
    sd = torch.load(CKPT, map_location="cpu")
    m.load_state_dict(sd["state_dict"]); m.eval()
    return m


def metrics(y_true, y_pred):
    acc = float((y_true == y_pred).mean())
    f1s = []
    for ci in range(len(POSTER_CLASSES)):
        tp = int(((y_pred == ci) & (y_true == ci)).sum())
        fp = int(((y_pred == ci) & (y_true != ci)).sum())
        fn = int(((y_pred != ci) & (y_true == ci)).sum())
        prec = tp / (tp + fp) if (tp + fp) else 0.0
        rec = tp / (tp + fn) if (tp + fn) else 0.0
        f1s.append(2 * prec * rec / (prec + rec) if (prec + rec) else 0.0)
    return round(acc, 4), round(float(np.mean(f1s)), 4)


def onnx_predict(path, X):
    import onnxruntime as ort
    sess = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    iname = sess.get_inputs()[0].name
    out = sess.run(None, {iname: X})
    # stroke_logits is output 0
    return np.asarray(out[0]).argmax(1)


def main():
    X, Y, _ = load_combined_split("test")
    X = X.astype(np.float32)
    print(f"test N={len(X)}")

    base = load_model()
    # 1) L1 unstructured prune 30%, bake in (remove reparam)
    params = [(m, "weight") for m in base.modules()
              if isinstance(m, (torch.nn.Conv2d, torch.nn.Linear))]
    prune.global_unstructured(params, pruning_method=prune.L1Unstructured, amount=PRUNE_AMOUNT)
    for m, n in params:
        prune.remove(m, n)
    nz = sum(int((p != 0).sum()) for p in base.parameters())
    tot = sum(p.numel() for p in base.parameters())
    print(f"pruned: nonzero={nz}/{tot} ({nz/tot:.3f})")

    # 2) export pruned model to ONNX (FP32)
    dummy = torch.randn(1, 3, T_TARGET, 17)

    class StrokeOnly(torch.nn.Module):
        def __init__(self, m): super().__init__(); self.m = m
        def forward(self, x):
            o = self.m(x)
            return o["stroke_logits"], o["features"]
    wrapper = StrokeOnly(base).eval()
    torch.onnx.export(
        wrapper, dummy, PRUNED_ONNX.as_posix(),
        input_names=["skeleton"], output_names=["stroke_logits", "features"],
        dynamic_axes={"skeleton": {0: "batch"}, "stroke_logits": {0: "batch"},
                      "features": {0: "batch"}},
        opset_version=17,
    )
    print(f"exported {PRUNED_ONNX.name} ({PRUNED_ONNX.stat().st_size/1024:.1f} KB)")

    # 3) dynamic INT8 quantize the pruned ONNX
    from onnxruntime.quantization import quantize_dynamic, QuantType
    quantize_dynamic(PRUNED_ONNX.as_posix(), PRUNED_INT8.as_posix(),
                     weight_type=QuantType.QInt8)
    print(f"quantized {PRUNED_INT8.name} ({PRUNED_INT8.stat().st_size/1024:.1f} KB)")

    # 4) measure all three on test set
    def lat(path):
        import onnxruntime as ort
        s = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
        n = s.get_inputs()[0].name
        for _ in range(5): s.run(None, {n: X[:1]})
        t0 = time.perf_counter()
        for i in range(100): s.run(None, {n: X[i % len(X):i % len(X)+1]})
        return round((time.perf_counter()-t0)/100*1000, 3)

    pruned_acc, pruned_f1 = metrics(Y, onnx_predict(PRUNED_ONNX, X))
    final_acc, final_f1 = metrics(Y, onnx_predict(PRUNED_INT8, X))

    fp32_onnx = CONV / "scorer_v3_fp32.onnx"
    fp32_acc, fp32_f1 = metrics(Y, onnx_predict(fp32_onnx, X))

    result = {
        "test_n": int(len(X)),
        "prune_amount": PRUNE_AMOUNT,
        "nonzero_fraction": round(nz / tot, 4),
        "stages": [
            {"name": "FP32 ONNX (baseline)", "size_kb": round(fp32_onnx.stat().st_size/1024, 1),
             "top1_acc": fp32_acc, "macro_f1": fp32_f1, "latency_ms": lat(fp32_onnx)},
            {"name": "Pruned 30% ONNX (FP32)", "size_kb": round(PRUNED_ONNX.stat().st_size/1024, 1),
             "top1_acc": pruned_acc, "macro_f1": pruned_f1, "latency_ms": lat(PRUNED_ONNX)},
            {"name": "Pruned 30% + Dynamic INT8 (SHIP)", "size_kb": round(PRUNED_INT8.stat().st_size/1024, 1),
             "top1_acc": final_acc, "macro_f1": final_f1, "latency_ms": lat(PRUNED_INT8)},
        ],
    }
    base_kb = result["stages"][0]["size_kb"]
    ship_kb = result["stages"][2]["size_kb"]
    result["headline"] = {
        "size_ratio": round(base_kb / ship_kb, 2),
        "acc_fp32": fp32_acc, "acc_final": final_acc,
        "acc_delta_pp": round((final_acc - fp32_acc) * 100, 2),
    }
    OUT_JSON.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")

    print("\n" + "=" * 64)
    for s in result["stages"]:
        print(f"{s['name']:<34}{s['size_kb']:>8}KB  {s['top1_acc']*100:>6.2f}%  {s['latency_ms']:>6}ms")
    print("=" * 64)
    print(f"compression {base_kb}->{ship_kb} KB = {result['headline']['size_ratio']}x | "
          f"acc {fp32_acc*100:.2f}%->{final_acc*100:.2f}% ({result['headline']['acc_delta_pp']:+.2f}pp)")
    print(f"JSON -> {OUT_JSON}")


if __name__ == "__main__":
    main()
