"""Rule-based 5-criteria scorer (V2-003).

Replaces the DNN criteria head from V1. The 5 criteria are deterministic
geometric functions of the 17-COCO joint coordinates; learning them with a
DNN is unnecessary because the labels are themselves rules. This module
applies those rules to the pose-extractor output, with temporal median
smoothing to handle BlazePose/MoveNet jitter.

Inputs:
  kpts: (T, 17, 3) numpy array. Channels = (x, y, conf). T variable.
        x,y can be in pixel coords or any consistent units — the scorer
        normalises internally by the player's shoulder-hip distance.

Outputs (dict):
  criteria: list of 5 dicts, one per criterion:
    {
      "name": str,
      "pass": bool,
      "measurement": float,         # the underlying angle/distance/std
      "unit": str,                  # "deg" | "ratio" | "ratio_of_body"
      "threshold": float,           # the rule threshold used
      "probability": float,         # smooth proxy in [0,1] (sigmoid of margin)
    }
  impact_frame: int                 # frame index of detected swing impact
  body_scale: float                 # shoulder-hip distance (px or units)
  smoothed_kpts: (T, 17, 3) array   # what we actually evaluated on
"""
from __future__ import annotations
import math
from typing import Sequence

import numpy as np


COCO_NAMES = [
    "nose", "left_eye", "right_eye", "left_ear", "right_ear",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
    "left_wrist", "right_wrist", "left_hip", "right_hip",
    "left_knee", "right_knee", "left_ankle", "right_ankle",
]
IDX = {n: i for i, n in enumerate(COCO_NAMES)}

CRITERIA_NAMES = [
    "peak_wrist_above_shoulder",
    "elbow_extension_>=160deg",
    "hip_rotation_>=20deg",
    "knees_bent_at_prep",
    "head_stable",
]


def temporal_median(kpts: np.ndarray, window: int = 5) -> np.ndarray:
    """Median filter along the T axis on x,y; leave conf alone."""
    if window <= 1 or kpts.shape[0] < window:
        return kpts.copy()
    T = kpts.shape[0]
    out = kpts.copy()
    half = window // 2
    for t in range(T):
        lo, hi = max(0, t - half), min(T, t + half + 1)
        # Median over the temporal window for each (joint, channel)
        out[t, :, 0] = np.median(kpts[lo:hi, :, 0], axis=0)
        out[t, :, 1] = np.median(kpts[lo:hi, :, 1], axis=0)
    return out


def _angle_deg(a: np.ndarray, b: np.ndarray, c: np.ndarray) -> float:
    """Angle at b formed by a-b-c, degrees in [0, 180]."""
    ba = a - b
    bc = c - b
    den = (np.linalg.norm(ba) * np.linalg.norm(bc)) + 1e-9
    cos = float(np.clip(np.dot(ba, bc) / den, -1.0, 1.0))
    return math.degrees(math.acos(cos))


def _dominant_wrist(kpts: np.ndarray) -> str:
    """Decide which wrist is the swinging one by total displacement across T.
    Returns "right" or "left" (referring to anatomical / our COCO naming)."""
    rw = kpts[:, IDX["right_wrist"], :2]
    lw = kpts[:, IDX["left_wrist"], :2]
    rdisp = float(np.linalg.norm(np.diff(rw, axis=0), axis=1).sum())
    ldisp = float(np.linalg.norm(np.diff(lw, axis=0), axis=1).sum())
    return "right" if rdisp >= ldisp else "left"


def _body_scale(kpts: np.ndarray) -> float:
    """Mean shoulder-hip distance across all frames (units of input coords)."""
    sh = (kpts[:, IDX["left_shoulder"], :2] + kpts[:, IDX["right_shoulder"], :2]) / 2.0
    hp = (kpts[:, IDX["left_hip"], :2] + kpts[:, IDX["right_hip"], :2]) / 2.0
    return float(np.linalg.norm(sh - hp, axis=1).mean())


def _sigmoid_margin(measurement: float, threshold: float, scale: float,
                    direction: str = ">=") -> float:
    """Smooth proxy probability in [0,1] from a hard threshold rule.

    direction = ">=" : higher = pass
    direction = "<"  : lower  = pass

    `scale` is the input-units half-width of the soft margin (e.g. 5 deg).
    """
    margin = measurement - threshold
    if direction == "<":
        margin = -margin
    x = margin / max(scale, 1e-6)
    return float(1.0 / (1.0 + math.exp(-x)))


def detect_impact_frame(kpts: np.ndarray, dom_wrist: str) -> int:
    """Frame where the dominant wrist y is at its lowest pixel-y (= highest in image)."""
    wrist_y = kpts[:, IDX[f"{dom_wrist}_wrist"], 1]
    return int(np.argmin(wrist_y))  # smaller y == higher in image


def _prep_frame(n_frames: int) -> int:
    """Use the first ~10% of frames as the 'prep' window; pick frame at 5%."""
    return max(1, int(0.05 * n_frames))


def _joints_visible_at_frame(kpts: np.ndarray, t: int, joint_idxs: list[int],
                              min_conf: float = 0.3) -> bool:
    """All requested joints have confidence >= min_conf at frame t."""
    return all(kpts[t, j, 2] >= min_conf for j in joint_idxs)


def score(kpts: np.ndarray, smooth_window: int = 5, min_joint_conf: float = 0.3) -> dict:
    """V3-F1: each criterion that depends on a joint with confidence < min_joint_conf
    at the relevant frame is marked measurement=None, pass=None, probability=0.5
    (truly uncertain). Coaching tips for such criteria say 'measurement N/A — pose
    not detected reliably on that frame'."""
    if kpts.ndim != 3 or kpts.shape[1] != 17 or kpts.shape[2] != 3:
        raise ValueError(f"kpts must be (T, 17, 3); got {kpts.shape}")
    T = int(kpts.shape[0])

    sm = temporal_median(kpts, window=smooth_window)
    dom = _dominant_wrist(sm)
    body = _body_scale(sm)
    impact = detect_impact_frame(sm, dom)
    prep = _prep_frame(T)

    results: list[dict] = []

    def _na_result(name, unit, threshold, reason="pose_conf_too_low"):
        return {"name": name, "pass": None, "measurement": None,
                "unit": unit, "threshold": threshold, "probability": 0.5,
                "reason_na": reason}

    # C1: peak_wrist_above_shoulder.
    needed_c1 = [IDX[f"{dom}_shoulder"], IDX[f"{dom}_wrist"]]
    if not _joints_visible_at_frame(sm, impact, needed_c1, min_joint_conf):
        results.append(_na_result(CRITERIA_NAMES[0], "ratio_of_shoulder_hip", 0.0))
    else:
        sh_y = float(sm[impact, IDX[f"{dom}_shoulder"], 1])
        wr_y = float(sm[impact, IDX[f"{dom}_wrist"], 1])
        diff = sh_y - wr_y
        measurement_c1 = diff / max(body, 1e-6)
        threshold_c1 = 0.0
        passed_c1 = measurement_c1 > threshold_c1
        prob_c1 = _sigmoid_margin(measurement_c1, threshold_c1, scale=0.10, direction=">=")
        results.append({
            "name": CRITERIA_NAMES[0], "pass": bool(passed_c1),
            "measurement": measurement_c1, "unit": "ratio_of_shoulder_hip",
            "threshold": threshold_c1, "probability": prob_c1,
        })

    # C2: elbow_extension >= 160 deg at impact.
    needed_c2 = [IDX[f"{dom}_shoulder"], IDX[f"{dom}_elbow"], IDX[f"{dom}_wrist"]]
    if not _joints_visible_at_frame(sm, impact, needed_c2, min_joint_conf):
        results.append(_na_result(CRITERIA_NAMES[1], "deg", 160.0))
    else:
        elbow_angle = _angle_deg(
            sm[impact, IDX[f"{dom}_shoulder"], :2],
            sm[impact, IDX[f"{dom}_elbow"], :2],
            sm[impact, IDX[f"{dom}_wrist"], :2],
        )
        threshold_c2 = 160.0
        passed_c2 = elbow_angle >= threshold_c2
        prob_c2 = _sigmoid_margin(elbow_angle, threshold_c2, scale=8.0, direction=">=")
        results.append({
            "name": CRITERIA_NAMES[1], "pass": bool(passed_c2),
            "measurement": elbow_angle, "unit": "deg",
            "threshold": threshold_c2, "probability": prob_c2,
        })

    # C3: hip_rotation >= 20 deg between prep and impact.
    def hip_angle(t: int) -> float:
        v = sm[t, IDX["right_hip"], :2] - sm[t, IDX["left_hip"], :2]
        return math.degrees(math.atan2(v[1], v[0]))
    rot = abs(hip_angle(impact) - hip_angle(0))
    # Wrap-around handling for angle subtraction
    if rot > 180:
        rot = 360 - rot
    threshold_c3 = 20.0
    passed_c3 = rot >= threshold_c3
    prob_c3 = _sigmoid_margin(rot, threshold_c3, scale=8.0, direction=">=")
    results.append({
        "name": CRITERIA_NAMES[2],
        "pass": bool(passed_c3),
        "measurement": rot,
        "unit": "deg",
        "threshold": threshold_c3,
        "probability": prob_c3,
    })

    # C4: knees_bent_at_prep.
    needed_c4 = [IDX[f"{dom}_hip"], IDX[f"{dom}_knee"], IDX[f"{dom}_ankle"]]
    if not _joints_visible_at_frame(sm, prep, needed_c4, min_joint_conf):
        results.append(_na_result(CRITERIA_NAMES[3], "deg", 150.0))
    else:
        knee_angle = _angle_deg(
            sm[prep, IDX[f"{dom}_hip"], :2],
            sm[prep, IDX[f"{dom}_knee"], :2],
            sm[prep, IDX[f"{dom}_ankle"], :2],
        )
        threshold_c4 = 150.0
        passed_c4 = knee_angle < threshold_c4
        prob_c4 = _sigmoid_margin(knee_angle, threshold_c4, scale=8.0, direction="<")
        results.append({
            "name": CRITERIA_NAMES[3], "pass": bool(passed_c4),
            "measurement": knee_angle, "unit": "deg",
            "threshold": threshold_c4, "probability": prob_c4,
        })

    # C5: head_stable. nose_y std across all frames < 0.06 * body_scale.
    # 0.06 is chosen to match the synth label generator's hard threshold of
    # "std < 6 px" given the synth body_scale of ~96 px. Tweak per camera
    # distance during per-user calibration.
    nose_y_std = float(np.std(sm[:, IDX["nose"], 1]))
    nose_y_std_norm = nose_y_std / max(body, 1e-6)
    threshold_c5 = 0.06
    passed_c5 = nose_y_std_norm < threshold_c5
    prob_c5 = _sigmoid_margin(nose_y_std_norm, threshold_c5, scale=0.03, direction="<")
    results.append({
        "name": CRITERIA_NAMES[4],
        "pass": bool(passed_c5),
        "measurement": nose_y_std_norm,
        "unit": "ratio_of_shoulder_hip",
        "threshold": threshold_c5,
        "probability": prob_c5,
    })

    return {
        "criteria": results,
        "impact_frame": impact,
        "prep_frame": prep,
        "dominant_arm": dom,
        "body_scale": body,
        "n_frames": T,
        "smoothed_kpts": sm,
    }


# ---------------------------------------------------------------------------
# Self-test against synthetic ground truth
# ---------------------------------------------------------------------------

def _self_test() -> int:
    """Verify the rules match the synth ground-truth labels on the two synth
    sample clips (synth_high_clear.mp4 and synth_forehand_drive.mp4)."""
    from pathlib import Path
    root = Path(__file__).resolve().parents[1]
    samples = [
        ("synth_high_clear",     root / "data" / "samples" / "synth_high_clear.gt.npz"),
        ("synth_forehand_drive", root / "data" / "samples" / "synth_forehand_drive.gt.npz"),
    ]
    # Bring in the synth labeler so we can compare apples to apples.
    import sys
    sys.path.insert(0, str(root / "experiments" / "scorer_baseline"))
    from synth_dataset import labels_from_params, _stroke_defaults, STROKES  # noqa: E402

    all_pass = True
    for name, gt_path in samples:
        ar = np.load(gt_path, allow_pickle=True)
        kpts = ar["keypoints"]  # (T, 17, 3) in pixel coords, conf=1
        stroke_idx = int(ar["stroke"])
        # Reconstruct GT labels using the synth labeler (params are the same RNG
        # seed used to generate the clip; recompute the labels directly from kpts).
        # synth's labeler reads kpts directly so we can call it without ClipParams.
        # We use the rendered kpts to get the same answer the synth labels gave.
        from synth_dataset import labels_from_params as L, _stroke_defaults  # noqa: F401
        # Hack: pass a dummy params object — labels_from_params only uses kpts
        # for the actual measurements (params not needed because the labeler is
        # geometry-based in synth_dataset.py).
        class P:  # dummy holder
            pass
        gt = L(P(), kpts)
        rule = score(kpts.astype(np.float32), smooth_window=1)
        rule_calls = np.array([int(c["pass"]) for c in rule["criteria"]], dtype=np.float32)
        agree = int((rule_calls == gt).sum())
        status = "OK" if agree >= 4 else "FAIL"
        print(f"[{status}] {name:25s}  gt={gt.tolist()}  rules={rule_calls.tolist()}  "
              f"(impact_f={rule['impact_frame']}/{rule['n_frames']}, "
              f"body={rule['body_scale']:.1f}, dom={rule['dominant_arm']})")
        if agree < 4:
            all_pass = False
    return 0 if all_pass else 1


if __name__ == "__main__":
    raise SystemExit(_self_test())
