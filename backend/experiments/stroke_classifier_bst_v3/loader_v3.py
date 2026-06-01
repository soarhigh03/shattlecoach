"""V3-B loader: ShuttleSet_25c + BadmintonDB + Top/Bottom mirror augmentation.

ShuttleSet 25c provides ~4,510 train clips for our 3 poster classes.
BadmintonDB adds another ~918 train clips from a completely different match
distribution (Ginting vs Momota series, 2018-2019 broadcasts). The two sources
have NO clip overlap.

Mirror augmentation: for each clip we use both the "labeled player" (the one
who executed the stroke per the directory name) AND its mirrored version
(left-right flip) — doubles the effective training set.
"""
from __future__ import annotations
import os
from pathlib import Path
from typing import Iterable
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
BST_25C = ROOT / "data" / "bst_npy" / "ShuttleSet_25c" / "dataset_npy"
BST_BDB = ROOT / "data" / "bst_npy" / "BadmintonDB" / "dataset_npy"

POSTER_CLASSES = ["high_clear", "short_serve", "forehand_drive"]

# ShuttleSet_25c uses Chinese stroke names with Top_/Bottom_ prefix.
SS25_MAP = {"長球": "high_clear", "發短球": "short_serve", "平球": "forehand_drive"}
# BadmintonDB uses English stroke names with Top-/Bottom- prefix.
BDB_MAP = {"Clear": "high_clear", "Serve": "short_serve", "Drive": "forehand_drive"}

T_TARGET = 32

# COCO-17 left/right pairs for mirroring (swap these to flip horizontally)
COCO_LR_PAIRS = [(1, 2), (3, 4), (5, 6), (7, 8), (9, 10), (11, 12), (13, 14), (15, 16)]


def _resample_T(arr: np.ndarray, t_out: int) -> np.ndarray:
    t_in = arr.shape[0]
    if t_in == t_out: return arr
    src = np.linspace(0, 1, t_in); dst = np.linspace(0, 1, t_out)
    out = np.empty((t_out, arr.shape[1], arr.shape[2]), dtype=arr.dtype)
    for j in range(arr.shape[1]):
        for c in range(arr.shape[2]):
            out[:, j, c] = np.interp(dst, src, arr[:, j, c])
    return out


def _mirror_horizontal(kpts: np.ndarray) -> np.ndarray:
    """kpts (T, 17, 3). Flip x sign + swap L/R joints. Keeps y and conf."""
    out = kpts.copy()
    out[..., 0] = -out[..., 0]
    for a, b in COCO_LR_PAIRS:
        out[:, [a, b], :] = out[:, [b, a], :]
    return out


def _iter_25c(split: str) -> Iterable[tuple[Path, int, int]]:
    sd = BST_25C / split
    if not sd.exists(): return
    for cls_dir in sorted(os.listdir(sd)):
        prefix = "Top_" if cls_dir.startswith("Top_") else ("Bottom_" if cls_dir.startswith("Bottom_") else None)
        if prefix is None: continue
        cn = cls_dir[len(prefix):]
        poster = SS25_MAP.get(cn)
        if poster is None: continue
        player_idx = 0 if prefix == "Top_" else 1
        cls_idx = POSTER_CLASSES.index(poster)
        for f in os.listdir(sd / cls_dir):
            if f.endswith("_joints.npy"):
                yield (sd / cls_dir / f, player_idx, cls_idx)


def _iter_bdb(split: str) -> Iterable[tuple[Path, int, int]]:
    sd = BST_BDB / split
    if not sd.exists(): return
    for cls_dir in sorted(os.listdir(sd)):
        if cls_dir.startswith("Top-"):   prefix, player_idx = "Top-", 0
        elif cls_dir.startswith("Bottom-"): prefix, player_idx = "Bottom-", 1
        else: continue
        en = cls_dir[len(prefix):]
        poster = BDB_MAP.get(en)
        if poster is None: continue
        cls_idx = POSTER_CLASSES.index(poster)
        for f in os.listdir(sd / cls_dir):
            if f.endswith("_joints.npy"):
                yield (sd / cls_dir / f, player_idx, cls_idx)


def load_combined_split(split: str, t_target: int = T_TARGET, mirror_aug: bool = True,
                        include_bdb: bool = True) -> tuple[np.ndarray, np.ndarray, list[str]]:
    """Returns (X, y, sources) where sources[i] in {'25c','bdb','25c-mirror','bdb-mirror'}."""
    Xs, ys, srcs = [], [], []
    for joints_path, player_idx, cls_idx in _iter_25c(split):
        j = np.load(joints_path)
        if j.ndim != 4 or j.shape[1] != 2 or j.shape[2] != 17 or j.shape[3] != 2: continue
        k = j[:, player_idx, :, :].astype(np.float32)
        k = _resample_T(k, t_target)
        c = np.ones(k.shape[:2] + (1,), dtype=np.float32)
        k3 = np.concatenate([k, c], axis=-1)
        Xs.append(np.transpose(k3, (2, 0, 1)).astype(np.float32))
        ys.append(cls_idx); srcs.append("25c")
        if mirror_aug:
            km = _mirror_horizontal(k3)
            Xs.append(np.transpose(km, (2, 0, 1)).astype(np.float32))
            ys.append(cls_idx); srcs.append("25c-mirror")
    if include_bdb:
        for joints_path, player_idx, cls_idx in _iter_bdb(split):
            j = np.load(joints_path)
            if j.ndim != 4 or j.shape[1] != 2 or j.shape[2] != 17 or j.shape[3] != 2: continue
            k = j[:, player_idx, :, :].astype(np.float32)
            k = _resample_T(k, t_target)
            c = np.ones(k.shape[:2] + (1,), dtype=np.float32)
            k3 = np.concatenate([k, c], axis=-1)
            Xs.append(np.transpose(k3, (2, 0, 1)).astype(np.float32))
            ys.append(cls_idx); srcs.append("bdb")
            if mirror_aug:
                km = _mirror_horizontal(k3)
                Xs.append(np.transpose(km, (2, 0, 1)).astype(np.float32))
                ys.append(cls_idx); srcs.append("bdb-mirror")
    if not Xs:
        raise RuntimeError(f"No clips for split={split}")
    X = np.stack(Xs, axis=0)
    y = np.array(ys, dtype=np.int64)
    return X, y, srcs


def main():
    for split in ("train", "val", "test"):
        X, y, srcs = load_combined_split(split, mirror_aug=True, include_bdb=True)
        counts = np.bincount(y, minlength=len(POSTER_CLASSES))
        from collections import Counter
        src_counts = Counter(srcs)
        print(f"[{split:5s}]  N={X.shape[0]:>6d}  shape={X.shape}")
        print(f"          classes: " + ", ".join(f"{POSTER_CLASSES[i]}={counts[i]}" for i in range(len(POSTER_CLASSES))))
        print(f"          sources: {dict(src_counts)}")

    out = Path(__file__).resolve().parent / "loader_v3_sanity.txt"
    lines = []
    for split in ("train", "val", "test"):
        X, y, srcs = load_combined_split(split)
        counts = np.bincount(y, minlength=len(POSTER_CLASSES))
        from collections import Counter
        src_counts = Counter(srcs)
        lines.append(f"[{split}] N={X.shape[0]} per-class={dict(zip(POSTER_CLASSES, counts.tolist()))} per-src={dict(src_counts)}")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines), encoding="utf-8")
    print(f"\n[ok] {out}")


if __name__ == "__main__":
    main()
