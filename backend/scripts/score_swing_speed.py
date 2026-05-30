"""V4-B1. Swing speed score: wrist velocity → 1-5 stars vs BST percentile.

Inputs: (T, 17, 3) keypoint array (T variable). Channels = (x, y, conf).
The scorer normalises velocity by body_scale internally so the result is
camera-distance-invariant.

The 1-5 star is calibrated against the distribution of max-wrist-velocity
across BST training clips (separately per stroke class is more accurate,
but for v0 we use a single combined distribution).

Usage as library:
    from scripts.score_swing_speed import score
    r = score(kpts, percentiles_npz=Path("path/to/swing_speed_percentiles.npz"))
    # r = {"max_velocity_norm": float, "mean_velocity_at_impact": float,
    #      "percentile_in_bst": int 1..99, "star": int 1..5}

Usage as script (compute BST percentiles once):
    python scripts/score_swing_speed.py --compute_percentiles
    python scripts/score_swing_speed.py --kpts data/samples/synth_high_clear.gt.npz
"""
from __future__ import annotations
import argparse, sys, time
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "experiments" / "stroke_classifier_bst"))
sys.path.insert(0, str(ROOT / "experiments" / "stroke_classifier_bst_v3"))
sys.path.insert(0, str(ROOT / "scripts"))

# COCO joint indices
IDX = {n: i for i, n in enumerate([
    "nose","left_eye","right_eye","left_ear","right_ear",
    "left_shoulder","right_shoulder","left_elbow","right_elbow",
    "left_wrist","right_wrist","left_hip","right_hip",
    "left_knee","right_knee","left_ankle","right_ankle",
])}

PERC_PATH = ROOT / "experiments" / "stroke_classifier_bst_v3" / "swing_speed_percentiles.npz"


def _dominant_wrist(kpts: np.ndarray) -> str:
    rw = kpts[:, IDX["right_wrist"], :2]
    lw = kpts[:, IDX["left_wrist"], :2]
    rd = float(np.linalg.norm(np.diff(rw, axis=0), axis=1).sum())
    ld = float(np.linalg.norm(np.diff(lw, axis=0), axis=1).sum())
    return "right" if rd >= ld else "left"


def _body_scale(kpts: np.ndarray) -> float:
    sh = (kpts[:, IDX["left_shoulder"], :2] + kpts[:, IDX["right_shoulder"], :2]) / 2
    hp = (kpts[:, IDX["left_hip"], :2] + kpts[:, IDX["right_hip"], :2]) / 2
    return float(np.linalg.norm(sh - hp, axis=1).mean())


def _wrist_velocity_features(kpts: np.ndarray) -> dict:
    """Returns dict with max_velocity_norm (body-units / frame),
    mean_velocity_at_impact (avg over 3-frame window around argmin(wrist_y)),
    and impact_frame index."""
    if kpts.shape[0] < 2:
        return {"max_velocity_norm": 0.0, "mean_velocity_at_impact": 0.0, "impact_frame": 0}
    dom = _dominant_wrist(kpts)
    body = max(_body_scale(kpts), 1e-6)
    wy = kpts[:, IDX[f"{dom}_wrist"], 1]
    impact = int(np.argmin(wy))
    wrist_xy = kpts[:, IDX[f"{dom}_wrist"], :2]
    diffs = np.diff(wrist_xy, axis=0)
    speeds = np.linalg.norm(diffs, axis=1) / body  # body-units / frame
    max_v = float(speeds.max()) if speeds.size else 0.0
    # 3-frame window centered on impact (clip to bounds)
    lo = max(0, impact - 1); hi = min(len(speeds), impact + 2)
    impact_speeds = speeds[lo:hi]
    mean_impact = float(impact_speeds.mean()) if impact_speeds.size else 0.0
    return {"max_velocity_norm": max_v, "mean_velocity_at_impact": mean_impact, "impact_frame": impact}


def _percentile_to_star(p: float) -> int:
    """Map [0,100] percentile to 1-5 stars. 80+ → 5, 60+ → 4, 40+ → 3, 20+ → 2, else 1."""
    if p >= 80: return 5
    if p >= 60: return 4
    if p >= 40: return 3
    if p >= 20: return 2
    return 1


def score(kpts: np.ndarray, percentiles_npz: Path | None = None) -> dict:
    feats = _wrist_velocity_features(kpts)
    p = 50  # default if no calibration data
    if percentiles_npz is None: percentiles_npz = PERC_PATH
    if percentiles_npz.exists():
        npz = np.load(percentiles_npz)
        sorted_bst = npz["sorted_max_velocity_norm"]
        # rank of our value among sorted_bst → percentile
        rank = float(np.searchsorted(sorted_bst, feats["max_velocity_norm"]))
        p = 100.0 * rank / max(len(sorted_bst), 1)
    return {
        "max_velocity_norm": feats["max_velocity_norm"],
        "mean_velocity_at_impact": feats["mean_velocity_at_impact"],
        "impact_frame": feats["impact_frame"],
        "percentile_in_bst": float(p),
        "star": _percentile_to_star(p),
        "calibration_source": str(percentiles_npz) if percentiles_npz.exists() else "uncalibrated (default p=50)",
    }


def compute_bst_percentiles(out_path: Path = PERC_PATH) -> None:
    """Compute max-wrist-velocity distribution across BST train clips."""
    from loader_v3 import load_combined_split  # noqa
    print("[V4-B1] loading BST train ...")
    X, _, _ = load_combined_split("train")
    print(f"  shape {X.shape}")
    # X is (N, 3, T, 17). Convert to (N, T, 17, 3) for the feature function.
    Xn = np.transpose(X, (0, 2, 3, 1)).astype(np.float32)
    max_v_list = []
    impact_v_list = []
    t0 = time.perf_counter()
    for i in range(Xn.shape[0]):
        f = _wrist_velocity_features(Xn[i])
        max_v_list.append(f["max_velocity_norm"])
        impact_v_list.append(f["mean_velocity_at_impact"])
    elapsed = time.perf_counter() - t0
    arr = np.asarray(max_v_list, dtype=np.float64)
    arr_imp = np.asarray(impact_v_list, dtype=np.float64)
    arr_sorted = np.sort(arr)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    np.savez(out_path,
             sorted_max_velocity_norm=arr_sorted,
             sorted_mean_velocity_at_impact=np.sort(arr_imp),
             n=np.int64(len(arr)),
             p10=np.float64(np.percentile(arr, 10)),
             p25=np.float64(np.percentile(arr, 25)),
             p50=np.float64(np.percentile(arr, 50)),
             p75=np.float64(np.percentile(arr, 75)),
             p90=np.float64(np.percentile(arr, 90)))
    print(f"[ok] {out_path}  ({elapsed:.1f}s for {len(arr)} clips)")
    print(f"  max_velocity_norm distribution: "
          f"p10={np.percentile(arr,10):.4f} p50={np.percentile(arr,50):.4f} "
          f"p90={np.percentile(arr,90):.4f} max={arr.max():.4f}")


def _self_test():
    """Smoke test against synth clips and (if available) one real clip."""
    print("[self-test] V4-B1 score_swing_speed")
    # Synth
    p = ROOT / "data" / "samples" / "synth_high_clear.gt.npz"
    if p.exists():
        npz = np.load(p, allow_pickle=True)
        r = score(npz["keypoints"])
        print(f"  synth_high_clear  star={r['star']} max_v={r['max_velocity_norm']:.4f} p={r['percentile_in_bst']:.1f}%")
    p = ROOT / "data" / "samples" / "synth_forehand_drive.gt.npz"
    if p.exists():
        npz = np.load(p, allow_pickle=True)
        r = score(npz["keypoints"])
        print(f"  synth_drive       star={r['star']} max_v={r['max_velocity_norm']:.4f} p={r['percentile_in_bst']:.1f}%")
    # Real (use any kpts already extracted)
    p = ROOT / "experiments" / "demo_v3" / "output_batch_final" / "jeugdkamp_clip00_overlay"
    if p.exists():
        # Don't have raw kpts there; reuse from V3 output if there's a kpts.npz
        pass
    print("[ok] self-test ran (errors above if any)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compute_percentiles", action="store_true",
                    help="Compute BST percentile distribution (run once)")
    ap.add_argument("--kpts", help="Path to .npz with 'keypoints' array (for testing)")
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
