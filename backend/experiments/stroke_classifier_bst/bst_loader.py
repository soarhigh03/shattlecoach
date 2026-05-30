"""BST data loader filtered to the 3 poster-relevant stroke classes.

V2-001. The BST dataset on disk at `data/bst_npy/ShuttleSet_25c/` stores each
clip as three .npy files keyed by a shared id:

  <id>_joints.npy   shape (T=25, 2 players, 17 joints, 2 xy)  float64
  <id>_pos.npy      shape (T, 2 players, 2 court_xy)
  <id>_shuttle.npy  shape (T, 2 xy)

Class names are Chinese (with Top_/Bottom_ prefix indicating which side of the
court the player is on). We filter to:

  長球     -> high_clear      (Top + Bottom merged)
  發短球   -> short_serve     (Top + Bottom merged)
  平球     -> forehand_drive  (Top + Bottom merged)

Low Clear is NOT a separate class in ShuttleSet; it is derived post-hoc at
inference time from peak wrist height when the classifier emits high_clear.

For input to ST-GCN we take ONLY the player who matches the side
(Top players' joints come from joints[:, 0], Bottom from joints[:, 1] — verified
empirically by the BST repo's load_data conventions). We add a confidence
channel = 1.0 since BST is pre-extracted (no per-joint confidence stored).

Output shape: (N, 3, T=T_TARGET, 17) — channels = (x, y, conf).

Note on T: BST train clips are 25 frames, val/test clips are 30 frames. We
linearly resample every clip to a common T_TARGET (default 32) so DataLoader
can batch them.
"""
from __future__ import annotations
import os
from pathlib import Path
from typing import Iterable

import numpy as np

BST_ROOT = Path(__file__).resolve().parents[2] / "data" / "bst_npy" / "ShuttleSet_25c" / "dataset_npy"

T_TARGET = 32

# Poster class -> ShuttleSet (Chinese) class. Index in returned y array follows POSTER_CLASSES order.
POSTER_CLASSES = ["high_clear", "short_serve", "forehand_drive"]
CN_TO_POSTER = {
    "長球": "high_clear",
    "發短球": "short_serve",
    "平球": "forehand_drive",
}


def _player_idx_from_dirname(cls_dir: str) -> int:
    """BST stacks two players per clip: index 0 = Top, index 1 = Bottom.

    The directory name encodes which player executed the stroke
    (e.g. Top_長球 means the top player hit a high clear)."""
    if cls_dir.startswith("Top_"):
        return 0
    if cls_dir.startswith("Bottom_"):
        return 1
    return -1


def _iter_clips(split: str) -> Iterable[tuple[Path, int, int]]:
    """Yield (joints_path, player_idx, poster_class_idx) for every clip in split."""
    split_dir = BST_ROOT / split
    if not split_dir.exists():
        raise FileNotFoundError(f"BST split not found: {split_dir}")
    for cls_dir in sorted(os.listdir(split_dir)):
        p = _player_idx_from_dirname(cls_dir)
        if p < 0:
            continue
        cn_name = cls_dir.split("_", 1)[1]  # e.g. "長球"
        poster = CN_TO_POSTER.get(cn_name)
        if poster is None:
            continue
        cls_idx = POSTER_CLASSES.index(poster)
        cls_path = split_dir / cls_dir
        for f in os.listdir(cls_path):
            if f.endswith("_joints.npy"):
                yield (cls_path / f, p, cls_idx)


def _resample_T(arr: np.ndarray, t_out: int) -> np.ndarray:
    """arr: (T, 17, 2). Linearly interpolate along T to t_out."""
    t_in = arr.shape[0]
    if t_in == t_out:
        return arr
    src = np.linspace(0, 1, t_in)
    dst = np.linspace(0, 1, t_out)
    out = np.empty((t_out, arr.shape[1], arr.shape[2]), dtype=arr.dtype)
    for j in range(arr.shape[1]):
        for c in range(arr.shape[2]):
            out[:, j, c] = np.interp(dst, src, arr[:, j, c])
    return out


def load_bst_split(split: str, t_target: int = T_TARGET) -> tuple[np.ndarray, np.ndarray]:
    """Returns (X, y) for `split` in {'train','val','test'}.

    X: (N, 3, t_target, 17)  float32  (channels: x, y, conf=1.0)
    y: (N,)                  int64    poster class index
    """
    Xs: list[np.ndarray] = []
    ys: list[int] = []
    skipped = 0
    for joints_path, player_idx, cls_idx in _iter_clips(split):
        j = np.load(joints_path)  # (T, 2, 17, 2)
        if j.ndim != 4 or j.shape[1] != 2 or j.shape[2] != 17 or j.shape[3] != 2:
            skipped += 1
            continue
        kpts = j[:, player_idx, :, :].astype(np.float32)  # (T_in, 17, 2)
        kpts = _resample_T(kpts, t_target)                # (t_target, 17, 2)
        conf = np.ones(kpts.shape[:2] + (1,), dtype=np.float32)  # (t_target, 17, 1)
        kpts3 = np.concatenate([kpts, conf], axis=-1)            # (t_target, 17, 3)
        x = np.transpose(kpts3, (2, 0, 1)).astype(np.float32)    # (3, t_target, 17)
        Xs.append(x)
        ys.append(cls_idx)
    if not Xs:
        raise RuntimeError(f"No clips found for split {split} under {BST_ROOT}; skipped {skipped}")
    X = np.stack(Xs, axis=0)
    y = np.array(ys, dtype=np.int64)
    return X, y


def main() -> int:
    rows: list[str] = []
    rows.append(f"BST root: {BST_ROOT}")
    rows.append(f"Poster classes (idx-ordered): {POSTER_CLASSES}")
    rows.append("")
    for split in ("train", "val", "test"):
        X, y = load_bst_split(split)
        counts = np.bincount(y, minlength=len(POSTER_CLASSES))
        rows.append(f"[{split:>5s}]  N = {X.shape[0]:>5d}   X shape = {X.shape}   y shape = {y.shape}")
        rows.append(f"          per-class counts: "
                    + ", ".join(f"{POSTER_CLASSES[i]}={counts[i]}" for i in range(len(POSTER_CLASSES))))
        rows.append(f"          x range = [{X[:, 0].min():.3f}, {X[:, 0].max():.3f}]  "
                    f"y range = [{X[:, 1].min():.3f}, {X[:, 1].max():.3f}]")
    out = "\n".join(rows)
    out_path = Path(__file__).resolve().parent / "sanity_check.txt"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(out, encoding="utf-8")
    print(out)
    print(f"\n[ok] wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
