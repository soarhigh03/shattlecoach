"""V4-B2. Step / footwork score: ankle dynamics → 1-5 stars vs BST percentile.

Inputs: (T, 17, 3) keypoint array. Channels = (x, y, conf).

Features computed:
  total_foot_path_norm     — sum of |Δankle|/body_scale across both ankles and time
  step_count               — # peaks in foot-velocity signal (rough proxy for # steps)
  hip_x_shift_norm         — |hip_x at impact - hip_x at prep| / body_scale (weight transfer)

Output star (1-5) is mapped from total_foot_path_norm percentile in BST.

Usage as library:
    from scripts.score_step import score
    r = score(kpts)

Usage as script (precompute BST percentiles once):
    python scripts/score_step.py --compute_percentiles
    python scripts/score_step.py --kpts <npz>
"""
from __future__ import annotations
import argparse, sys, time
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "experiments" / "stroke_classifier_bst_v3"))

IDX = {n: i for i, n in enumerate([
    "nose","left_eye","right_eye","left_ear","right_ear",
    "left_shoulder","right_shoulder","left_elbow","right_elbow",
    "left_wrist","right_wrist","left_hip","right_hip",
    "left_knee","right_knee","left_ankle","right_ankle",
])}

PERC_PATH = ROOT / "experiments" / "stroke_classifier_bst_v3" / "step_percentiles.npz"


def _body_scale(kpts: np.ndarray) -> float:
    sh = (kpts[:, IDX["left_shoulder"], :2] + kpts[:, IDX["right_shoulder"], :2]) / 2
    hp = (kpts[:, IDX["left_hip"], :2] + kpts[:, IDX["right_hip"], :2]) / 2
    return float(np.linalg.norm(sh - hp, axis=1).mean())


def _count_velocity_peaks(speeds: np.ndarray, min_prom: float = 0.05) -> int:
    """Local maxima with prominence > min_prom * max(speeds)."""
    if speeds.size < 3: return 0
    thr = min_prom * float(speeds.max() + 1e-9)
    peaks = 0
    for i in range(1, len(speeds) - 1):
        if speeds[i] > speeds[i-1] and speeds[i] > speeds[i+1] and speeds[i] > thr:
            peaks += 1
    return peaks


def _step_features(kpts: np.ndarray) -> dict:
    if kpts.shape[0] < 2:
        return {"total_foot_path_norm": 0.0, "step_count": 0,
                "hip_x_shift_norm": 0.0, "impact_frame": 0}
    body = max(_body_scale(kpts), 1e-6)
    la = kpts[:, IDX["left_ankle"], :2]
    ra = kpts[:, IDX["right_ankle"], :2]
    la_speeds = np.linalg.norm(np.diff(la, axis=0), axis=1) / body
    ra_speeds = np.linalg.norm(np.diff(ra, axis=0), axis=1) / body
    total_path = float(la_speeds.sum() + ra_speeds.sum())
    step_count = _count_velocity_peaks(la_speeds) + _count_velocity_peaks(ra_speeds)
    # impact frame = wrist-y peak (same as speed module)
    rw_y = kpts[:, IDX["right_wrist"], 1]
    lw_y = kpts[:, IDX["left_wrist"], 1]
    impact = int(np.argmin(np.minimum(rw_y, lw_y)))
    prep = max(1, int(0.05 * kpts.shape[0]))
    # weight transfer = hip x movement between prep and impact
    hip_x_prep = float((kpts[prep, IDX["left_hip"], 0] + kpts[prep, IDX["right_hip"], 0]) / 2)
    hip_x_imp = float((kpts[impact, IDX["left_hip"], 0] + kpts[impact, IDX["right_hip"], 0]) / 2)
    hip_shift = abs(hip_x_imp - hip_x_prep) / body
    return {
        "total_foot_path_norm": total_path,
        "step_count": int(step_count),
        "hip_x_shift_norm": float(hip_shift),
        "impact_frame": impact,
    }


def _percentile_to_star(p: float) -> int:
    if p >= 80: return 5
    if p >= 60: return 4
    if p >= 40: return 3
    if p >= 20: return 2
    return 1


def score(kpts: np.ndarray, percentiles_npz: Path | None = None) -> dict:
    f = _step_features(kpts)
    p = 50
    if percentiles_npz is None: percentiles_npz = PERC_PATH
    if percentiles_npz.exists():
        npz = np.load(percentiles_npz)
        sorted_paths = npz["sorted_total_foot_path_norm"]
        rank = float(np.searchsorted(sorted_paths, f["total_foot_path_norm"]))
        p = 100.0 * rank / max(len(sorted_paths), 1)
    return {
        "total_foot_path_norm": f["total_foot_path_norm"],
        "step_count": f["step_count"],
        "hip_x_shift_norm": f["hip_x_shift_norm"],
        "impact_frame": f["impact_frame"],
        "percentile_in_bst": float(p),
        "star": _percentile_to_star(p),
        "calibration_source": str(percentiles_npz) if percentiles_npz.exists() else "uncalibrated",
    }


def compute_bst_percentiles(out_path: Path = PERC_PATH) -> None:
    from loader_v3 import load_combined_split
    print("[V4-B2] loading BST train ...")
    X, _, _ = load_combined_split("train")
    Xn = np.transpose(X, (0, 2, 3, 1)).astype(np.float32)
    t0 = time.perf_counter()
    paths = []; steps = []; shifts = []
    for i in range(Xn.shape[0]):
        f = _step_features(Xn[i])
        paths.append(f["total_foot_path_norm"])
        steps.append(f["step_count"])
        shifts.append(f["hip_x_shift_norm"])
    arr = np.sort(np.asarray(paths, dtype=np.float64))
    out_path.parent.mkdir(parents=True, exist_ok=True)
    np.savez(out_path,
             sorted_total_foot_path_norm=arr,
             sorted_hip_x_shift_norm=np.sort(np.asarray(shifts, dtype=np.float64)),
             step_count_distribution=np.asarray(steps, dtype=np.int32),
             n=np.int64(len(arr)),
             p10=np.float64(np.percentile(arr, 10)),
             p50=np.float64(np.percentile(arr, 50)),
             p90=np.float64(np.percentile(arr, 90)))
    print(f"[ok] {out_path} ({time.perf_counter()-t0:.1f}s, n={len(arr)})")
    print(f"  total_foot_path_norm distribution: p10={np.percentile(arr,10):.4f} "
          f"p50={np.percentile(arr,50):.4f} p90={np.percentile(arr,90):.4f}")


def _self_test():
    print("[self-test] V4-B2 score_step")
    for n in ("synth_high_clear", "synth_forehand_drive"):
        p = ROOT / "data" / "samples" / f"{n}.gt.npz"
        if not p.exists(): continue
        npz = np.load(p, allow_pickle=True)
        r = score(npz["keypoints"])
        print(f"  {n}  star={r['star']} foot_path={r['total_foot_path_norm']:.4f} "
              f"steps={r['step_count']} hip_shift={r['hip_x_shift_norm']:.4f}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compute_percentiles", action="store_true")
    ap.add_argument("--kpts", help="Path to .npz with 'keypoints'")
    args = ap.parse_args()
    if args.compute_percentiles:
        compute_bst_percentiles(); return 0
    if args.kpts:
        npz = np.load(args.kpts, allow_pickle=True)
        import json
        print(json.dumps(score(npz["keypoints"]), indent=2)); return 0
    _self_test()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
