"""V3-B train: ST-GCN on the expanded ShuttleSet_25c + BadmintonDB + mirror-augmented corpus."""
from __future__ import annotations
import argparse, json, math, sys, time
from dataclasses import dataclass, asdict
from pathlib import Path
import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader, TensorDataset

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(ROOT / "experiments" / "scorer_baseline"))
from loader_v3 import load_combined_split, POSTER_CLASSES, T_TARGET  # noqa: E402
from stgcn import STGCN, count_params  # noqa: E402


@dataclass
class Config:
    epochs: int = 15
    batch_size: int = 128
    lr: float = 3e-3
    weight_decay: float = 1e-4
    seed: int = 2027
    out_dir: str = ""


def evaluate(model, loader, n_classes):
    model.eval()
    correct = 0; total = 0
    conf = np.zeros((n_classes, n_classes), dtype=np.int64)
    with torch.no_grad():
        for X, y in loader:
            pred = model(X)["stroke_logits"].argmax(dim=1).numpy()
            yn = y.numpy()
            for p, t in zip(pred, yn): conf[int(t), int(p)] += 1
            correct += int((pred == yn).sum()); total += int(yn.size)
    per_p, per_r = [], []
    for k in range(n_classes):
        tp = int(conf[k, k]); fp = int(conf[:, k].sum() - tp); fn = int(conf[k, :].sum() - tp)
        per_p.append(tp / max(tp + fp, 1e-9))
        per_r.append(tp / max(tp + fn, 1e-9))
    return {"top1_acc": correct / max(total, 1), "n": int(total),
            "confusion": conf.tolist(),
            "per_class_precision": per_p, "per_class_recall": per_r,
            "per_class_f1": [2*p*r / max(p+r,1e-9) for p, r in zip(per_p, per_r)]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=15)
    ap.add_argument("--batch_size", type=int, default=128)
    ap.add_argument("--lr", type=float, default=3e-3)
    ap.add_argument("--out_dir", default="")
    args = ap.parse_args()
    cfg = Config(epochs=args.epochs, batch_size=args.batch_size, lr=args.lr, out_dir=args.out_dir)
    torch.manual_seed(cfg.seed); np.random.seed(cfg.seed)
    od = Path(cfg.out_dir or Path(__file__).resolve().parent)
    od.mkdir(parents=True, exist_ok=True)
    with open(od / "config.yaml", "w", encoding="utf-8") as f:
        for k, v in asdict(cfg).items(): f.write(f"{k}: {v}\n")

    print("[load] combined corpus (25c + BDB + mirror) ...")
    Xtr, ytr, _ = load_combined_split("train")
    Xva, yva, _ = load_combined_split("val")
    Xte, yte, _ = load_combined_split("test")
    print(f"  train {Xtr.shape}, val {Xva.shape}, test {Xte.shape}")
    def L(X, y, sh):
        return DataLoader(TensorDataset(torch.from_numpy(X), torch.from_numpy(y)),
                          batch_size=cfg.batch_size, shuffle=sh)
    tr, va, te = L(Xtr, ytr, True), L(Xva, yva, False), L(Xte, yte, False)

    K = len(POSTER_CLASSES)
    model = STGCN(in_channels=3, n_strokes=K, n_criteria=1)
    n_params = count_params(model)
    print(f"[info] params={n_params}")
    opt = torch.optim.AdamW(model.parameters(), lr=cfg.lr, weight_decay=cfg.weight_decay)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=cfg.epochs)
    ce = nn.CrossEntropyLoss(label_smoothing=0.05)

    log = [f"params={n_params}", f"poster_classes={POSTER_CLASSES}",
           f"train_n={len(tr.dataset)} val_n={len(va.dataset)} test_n={len(te.dataset)}",
           f"T_TARGET={T_TARGET} label_smoothing=0.05"]
    best = -math.inf; best_state = None
    for ep in range(1, cfg.epochs + 1):
        model.train()
        t0 = time.perf_counter()
        losses = []
        for X, y in tr:
            out = model(X)
            loss = ce(out["stroke_logits"], y)
            opt.zero_grad(); loss.backward(); opt.step()
            losses.append(float(loss.item()))
        sched.step()
        vm = evaluate(model, va, K)
        line = f"ep={ep:02d} loss={np.mean(losses):.4f} val_top1={vm['top1_acc']:.4f} sec={time.perf_counter()-t0:.1f}"
        print(line); log.append(line)
        if vm["top1_acc"] > best:
            best = vm["top1_acc"]
            best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}

    if best_state is not None: model.load_state_dict(best_state)
    torch.save({"state_dict": model.state_dict(), "config": asdict(cfg),
                "poster_classes": POSTER_CLASSES, "T_TARGET": T_TARGET},
               od / "checkpoint.pt")
    val_f = evaluate(model, va, K); test_f = evaluate(model, te, K)
    one = next(iter(te))[0][:1]
    model.eval()
    with torch.no_grad():
        for _ in range(3): model(one)
        ts = []
        for _ in range(20):
            t0 = time.perf_counter(); model(one); ts.append((time.perf_counter()-t0)*1000)
    lat = {"cpu_latency_ms_mean": float(np.mean(ts)), "cpu_latency_ms_p95": float(np.percentile(ts, 95))}
    blob = {"architecture": "ST-GCN v3 (BST_25c + BadmintonDB + mirror aug)",
            "data_source": "ShuttleSet_25c + BadmintonDB, 2x mirror aug",
            "poster_classes": POSTER_CLASSES, "params": n_params, "epochs": cfg.epochs,
            "val": val_f, "test": test_f, "latency_cpu": lat, "T_TARGET": T_TARGET}
    with open(od / "eval.json", "w", encoding="utf-8") as f: json.dump(blob, f, indent=2)
    with open(od / "training_log.txt", "w", encoding="utf-8") as f: f.write("\n".join(log))
    print(json.dumps({k: v for k, v in blob.items() if k not in ("val", "test", "latency_cpu")}, indent=2))
    print(f"[ok] V3 test top1 = {test_f['top1_acc']:.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
