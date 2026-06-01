"""V4-B3 demo: 3-axis score (posture / speed / step) + drops low_clear.

Pipeline:
  video → MediaPipe BlazePose (or GT skeleton) → 17 COCO keypoints
       → 3 parallel scorers:
            posture = rule-based 5 criteria (existing system, per-class thresholds)
            speed   = wrist-velocity percentile in BST
            step    = ankle-dynamics percentile in BST
       → BST classifier (V3, with temperature + Mahalanobis OOD)
       → coaching JSON with 3 separate star ratings

NO low_clear post-hoc rule. 3 strokes only (high_clear / short_serve / forehand_drive).
"""
from __future__ import annotations
import argparse, json, sys, time
from pathlib import Path
import cv2
import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "experiments" / "scorer_baseline"))
sys.path.insert(0, str(ROOT / "experiments" / "stroke_classifier_bst"))
sys.path.insert(0, str(ROOT / "experiments" / "stroke_classifier_bst_v3"))
sys.path.insert(0, str(ROOT / "scripts"))

from stgcn import STGCN  # noqa: E402
from bst_loader import POSTER_CLASSES, T_TARGET  # noqa: E402
from rule_based_scorer import score as posture_score, IDX  # noqa: E402
from extract_pose import extract_mediapipe, _draw_skeleton  # noqa: E402
import score_swing_speed as ssp  # noqa: E402
import score_step as sst  # noqa: E402

CKPT_V3 = ROOT / "experiments" / "stroke_classifier_bst_v3" / "checkpoint.pt"
TEMP_JSON = ROOT / "experiments" / "stroke_classifier_bst_v3" / "temperature.json"
OOD_NPZ = ROOT / "experiments" / "stroke_classifier_bst_v3" / "ood_mahalanobis.npz"
RULE_CALIB = ROOT / "experiments" / "stroke_classifier_bst_v3" / "rule_calibration.json"
STROKE_AXES_JSON = ROOT / "scripts" / "stroke_axes.json"

POSE_DET_REJECT = 0.50


try:
    sys.path.insert(0, str(ROOT / "scripts"))
    from annotate_frame import annotate_impact  # type: ignore  # noqa: E402
except Exception as _e:
    annotate_impact = None  # type: ignore[assignment]
    print(f"[warn] annotate_frame import failed: {_e}; visualization will be skipped")


def _load_stroke_axes_config():
    if not STROKE_AXES_JSON.exists():
        print(f"[warn] {STROKE_AXES_JSON} missing — keeping all axes for every stroke")
        return None
    try:
        return json.loads(STROKE_AXES_JSON.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"[warn] failed to parse {STROKE_AXES_JSON}: {e} — keeping all axes")
        return None


def apply_stroke_axis_filter(payload: dict) -> dict:
    """Null-out irrelevant axes per stroke + filter coaching_tips + add reasons.

    Reads scripts/stroke_axes.json. Fail-soft: if config missing, returns payload unchanged.
    Adds top-level 'axes_evaluated' (list) and 'axes_dropped' ({axis: reason}) for transparency.
    """
    cfg = _load_stroke_axes_config()
    all_axes = ["posture", "speed", "step"]
    if cfg is None:
        payload["axes_evaluated"] = all_axes
        payload["axes_dropped"] = {}
        return payload
    label = payload.get("stroke", {}).get("label", "")
    entry = cfg.get(label) or cfg.get("unknown_ood") or {"axes": all_axes, "reasons": {}}
    relevant = list(entry.get("axes", all_axes))
    reasons = dict(entry.get("reasons", {}))
    for axis in all_axes:
        # Dropped axes: omit *_stars/*_reason entirely (no N/A). Reason kept in axes_dropped.
        if axis not in relevant:
            payload.pop(f"{axis}_stars", None)
        payload.pop(f"{axis}_reason", None)
    # Filter coaching tips to relevant axes only
    payload["coaching_tips"] = [t for t in payload.get("coaching_tips", []) if t.get("axis") in relevant]
    payload["axes_evaluated"] = relevant
    payload["axes_dropped"] = {a: reasons.get(a, f"{a} not relevant for {label}") for a in all_axes if a not in relevant}
    return payload

COACHING_TIPS = {
    "peak_wrist_above_shoulder": ("임팩트 순간에 라켓 손이 어깨보다 위로 올라오는지 확인하세요.",
                                   "Raise the racket-hand above shoulder height at impact."),
    "elbow_extension_>=160deg":  ("팔꿈치를 더 펴서 임팩트하세요 (거의 일직선).",
                                   "Extend the elbow nearly straight at impact."),
    "hip_rotation_>=20deg":      ("엉덩이/허리 회전을 더 크게 사용해 보세요.",
                                   "Use more hip/torso rotation to drive the swing."),
    "knees_bent_at_prep":        ("준비 자세에서 무릎을 더 굽혀 낮은 스탠스를 유지하세요.",
                                   "Bend the knees more in the preparation stance."),
}

SPEED_TIPS = {
    1: ("스윙 속도가 평균보다 매우 느려요. 손목 스냅을 더 빠르게.", "Swing very slow — snap the wrist faster."),
    2: ("스윙 속도가 살짝 느려요. 임팩트 직전 가속을 의식하세요.", "Slightly slow — focus on acceleration before impact."),
    3: ("평균적인 스윙 속도예요.", "Average swing speed."),
    4: ("좋은 스윙 속도예요.", "Good swing speed."),
    5: ("매우 빠른 스윙. 컨트롤만 유지하면 강력해요.", "Very fast swing — maintain control."),
}

STEP_TIPS = {
    1: ("발이 거의 안 움직였어요. 셔틀 따라 스텝 사용해 보세요.", "Very little footwork — use steps to chase the shuttle."),
    2: ("스텝이 조금 부족해요.", "Slightly limited footwork."),
    3: ("평균적인 풋워크예요.", "Average footwork."),
    4: ("활발한 풋워크예요.", "Active footwork."),
    5: ("매우 활발한 풋워크.", "Very active footwork."),
}


def _temporal_resample(arr, t_out):
    t_in = arr.shape[0]
    if t_in == t_out: return arr
    src = np.linspace(0, 1, t_in); dst = np.linspace(0, 1, t_out)
    out = np.empty((t_out, arr.shape[1], arr.shape[2]), dtype=arr.dtype)
    for j in range(arr.shape[1]):
        for c in range(arr.shape[2]):
            out[:, j, c] = np.interp(dst, src, arr[:, j, c])
    return out


def _normalise_for_model(kpts):
    out = kpts.copy().astype(np.float32)
    lh = out[:, IDX["left_hip"], :2]; rh = out[:, IDX["right_hip"], :2]
    mid_hip = (lh + rh) / 2.0
    ls = out[:, IDX["left_shoulder"], :2]; rs = out[:, IDX["right_shoulder"], :2]
    mid_sh = (ls + rs) / 2.0
    scale = float(np.linalg.norm(mid_sh - mid_hip, axis=1).mean()) + 1e-6
    out[..., :2] = (out[..., :2] - mid_hip[:, None, :]) / scale
    return out


def _mahalanobis_min(feat, centroids, inv_cov):
    out = np.empty(centroids.shape[0], dtype=np.float64)
    for k in range(centroids.shape[0]):
        d = feat - centroids[k]
        out[k] = float(d @ inv_cov @ d)
    return float(out.min()), int(out.argmin())


def classify(kpts):
    norm = _normalise_for_model(kpts)
    res = _temporal_resample(norm, T_TARGET)
    inp = torch.from_numpy(np.transpose(res, (2, 0, 1))[None, ...]).float()
    model = STGCN(in_channels=3, n_strokes=len(POSTER_CLASSES), n_criteria=1)
    state = torch.load(CKPT_V3, map_location="cpu")
    model.load_state_dict(state["state_dict"]); model.eval()
    with torch.no_grad():
        t0 = time.perf_counter(); out = model(inp); ms = (time.perf_counter()-t0)*1000
    logits = out["stroke_logits"][0].numpy()
    feat = out["features"][0].numpy()
    T = json.loads(TEMP_JSON.read_text(encoding="utf-8"))["temperature"]
    scaled = logits / T
    probs = np.exp(scaled - scaled.max()); probs = probs / probs.sum()
    ood = np.load(OOD_NPZ)
    mdist, nearest = _mahalanobis_min(feat, ood["centroids"], ood["inv_cov"])
    thr = float(ood["threshold_95"])
    return {
        "label": POSTER_CLASSES[int(np.argmax(probs))] if mdist <= thr else "unknown_ood",
        "softmax_3class": {POSTER_CLASSES[i]: float(probs[i]) for i in range(len(POSTER_CLASSES))},
        "top1_confidence": float(np.max(probs)),
        "scorer_ms": ms,
        "T_used": float(T),
        "is_ood": mdist > thr,
        "mahalanobis_distance": mdist,
        "ood_threshold_95": thr,
    }


def apply_per_class_thresholds(posture_out, predicted_class, is_ood, mdist_ratio):
    if not RULE_CALIB.exists():
        return posture_out
    calib = json.loads(RULE_CALIB.read_text(encoding="utf-8"))
    extreme = is_ood and mdist_ratio > 1e6
    if predicted_class in calib["per_class"] and not extreme:
        thrs = calib["per_class"][predicted_class]
        source = f"per-class ({predicted_class})"
    else:
        thrs = calib["global"]; source = "global"
    new = []
    for c in posture_out["criteria"]:
        name = c["name"]
        if c.get("measurement") is None:
            new.append({**c, "calibration_source": "n/a (low pose conf)"}); continue
        if name not in thrs: new.append(c); continue
        t = thrs[name]; thr_v = float(t["threshold"]); d = t["direction"]
        m = float(c["measurement"])
        passed = (m >= thr_v) if d == ">=" else (m < thr_v)
        import math
        margin = (m - thr_v) if d == ">=" else (thr_v - m)
        scale = max(abs(thr_v) * 0.2, 1e-3)
        prob = 1.0 / (1.0 + math.exp(-margin / scale))
        new.append({"name": name, "pass": bool(passed), "probability": float(prob),
                    "measurement": m, "unit": c["unit"], "threshold": thr_v,
                    "calibration_source": source})
    posture_out["criteria"] = new
    posture_out["threshold_source"] = source
    return posture_out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", required=True)
    ap.add_argument("--out_dir", default=str(ROOT / "experiments" / "demo_v4" / "output"))
    ap.add_argument("--stroke", default=None,
                    choices=["high_clear", "short_serve", "forehand_drive"],
                    help="User-selected stroke (점5). Bypasses the ST-GCN/OOD for scoring "
                         "decisions: drives axis filter + per-class thresholds, restoring "
                         "speed/step that OOD would otherwise drop (D1).")
    args = ap.parse_args()
    for p in (CKPT_V3, TEMP_JSON, OOD_NPZ):
        if not p.exists(): raise FileNotFoundError(p)

    vid = Path(args.video); stem = vid.stem
    od = Path(args.out_dir); od.mkdir(parents=True, exist_ok=True)
    overlay_dir = od / f"{stem}_overlay"; overlay_dir.mkdir(parents=True, exist_ok=True)

    gt = vid.with_suffix(".gt.npz")
    if gt.exists():
        ar = np.load(gt, allow_pickle=True)
        kpts = ar["keypoints"].astype(np.float32); w, h = int(ar["width"]), int(ar["height"])
        backend = "gt_synth"; t_ext = 0.0
    else:
        t0 = time.perf_counter()
        kpts, w, h = extract_mediapipe(str(vid))
        t_ext = time.perf_counter() - t0; backend = "mediapipe"
    n_frames = int(kpts.shape[0])
    det = float((kpts[..., 2].max(axis=1) > 0).mean()) if backend == "mediapipe" else 1.0
    print(f"[info] {backend} frames={n_frames} det={det:.3f}")

    if det < POSE_DET_REJECT:
        payload = {"version": "v4", "video": str(vid), "n_frames": n_frames,
                   "pose_backend": backend, "pose_detection_rate": det,
                   "status": "REJECTED_LOW_POSE_DETECTION",
                   "message_ko": f"영상에서 사람을 잘 인식하지 못했어요 ({det*100:.0f}%)."}
        (od / f"{stem}_score.json").write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"[REJECT] det={det:.2f}"); return 0

    posture = posture_score(kpts, smooth_window=5)
    stroke = classify(kpts)
    speed = ssp.score(kpts)
    step = sst.score(kpts)
    # 점5/D1: a user-selected stroke is authoritative — keep the classifier output
    # as a reference but bypass it (and OOD) for all scoring decisions.
    if args.stroke:
        stroke = {
            **stroke,
            "classifier_reference": {
                "label": stroke.get("label"), "is_ood": stroke.get("is_ood"),
                "top1_confidence": stroke.get("top1_confidence"),
                "softmax_3class": stroke.get("softmax_3class"),
                "mahalanobis_distance": stroke.get("mahalanobis_distance"),
            },
            "label": args.stroke, "is_ood": False, "source": "user_selected",
        }
    scoring_label = stroke["label"]
    posture = apply_per_class_thresholds(posture, scoring_label, stroke["is_ood"],
                                          stroke["mahalanobis_distance"] / max(stroke["ood_threshold_95"], 1e-9))

    valid_probs = [c["probability"] for c in posture["criteria"] if c.get("measurement") is not None]
    posture_stars = int(round(1 + 4 * float(np.mean(valid_probs)))) if valid_probs else None

    # Coaching tips: posture (per failed criterion) + speed (if not avg) + step (if not avg)
    tips = []
    for c in posture["criteria"]:
        if c.get("measurement") is None:
            tips.append({"axis": "posture", "criterion": c["name"], "tip_ko": "이 항목은 측정 불가 (관절이 안 보여요).",
                         "tip_en": "Could not measure (joint not visible).", "measurement": None,
                         "threshold": float(c["threshold"])})
        elif not c["pass"]:
            ko, en = COACHING_TIPS[c["name"]]
            tips.append({"axis": "posture", "criterion": c["name"], "tip_ko": ko, "tip_en": en,
                         "measurement": float(c["measurement"]), "threshold": float(c["threshold"])})
    if speed["star"] != 3:
        ko, en = SPEED_TIPS[speed["star"]]
        tips.append({"axis": "speed", "criterion": "swing_speed", "tip_ko": ko, "tip_en": en,
                     "measurement": speed["max_velocity_norm"], "threshold": None})
    if step["star"] != 3:
        ko, en = STEP_TIPS[step["star"]]
        tips.append({"axis": "step", "criterion": "footwork", "tip_ko": ko, "tip_en": en,
                     "measurement": step["total_foot_path_norm"], "threshold": None})

    # Overlay frames
    overlay_paths = []
    cap = cv2.VideoCapture(str(vid))
    if cap.isOpened():
        sample_idx = np.linspace(0, n_frames - 1, 10).astype(int)
        for i, fi in enumerate(sample_idx):
            cap.set(cv2.CAP_PROP_POS_FRAMES, int(fi))
            ok, frame = cap.read()
            if not ok: continue
            overlaid = _draw_skeleton(frame, kpts[fi])
            p = overlay_dir / f"frame_{i:02d}.png"
            cv2.imwrite(str(p), overlaid)
            try:
                rel = p.relative_to(ROOT)
                overlay_paths.append(str(rel).replace("\\", "/"))
            except ValueError:
                overlay_paths.append(str(p).replace("\\", "/"))
        cap.release()

    payload = {
        "version": "v4",
        "video": str(vid), "n_frames": n_frames, "resolution": [int(w), int(h)],
        "pose_backend": backend, "pose_detection_rate": det,
        "pose_extraction_seconds": round(t_ext, 3),
        "scorer_inference_ms": round(stroke["scorer_ms"], 3),
        "status": "OK",
        "stroke": {
            "label": stroke["label"],
            "softmax_3class": stroke["softmax_3class"],
            "top1_confidence": stroke["top1_confidence"],
            "calibration_T": stroke["T_used"],
            "is_ood": stroke["is_ood"],
            "mahalanobis_distance": stroke["mahalanobis_distance"],
            "available_strokes": POSTER_CLASSES + ["unknown_ood"],
            "note": "low_clear removed in v4 — kept as 3-stroke output until shuttle tracking added in v1",
            **({"source": stroke["source"], "classifier_reference": stroke["classifier_reference"]}
               if stroke.get("source") == "user_selected" else {}),
        },
        # 3-axis scores
        "posture_stars": posture_stars,
        "posture_criteria": posture["criteria"],
        "posture_threshold_source": posture.get("threshold_source", "synth"),
        "speed_stars": speed["star"],
        "speed_details": {k: v for k, v in speed.items() if k != "star"},
        "step_stars": step["star"],
        "step_details": {k: v for k, v in step.items() if k != "star"},
        # radar (combined)
        "radar": {**{f"posture/{c['name']}": float(c["probability"]) for c in posture["criteria"]},
                  "speed": speed["percentile_in_bst"] / 100, "step": step["percentile_in_bst"] / 100},
        "coaching_tips": tips,
        "overlay_frames": overlay_paths,
    }
    payload = apply_stroke_axis_filter(payload)

    # V6-VIZ1: annotated impact-frame PNG embedded as base64
    if annotate_impact is not None:
        try:
            fps_guess = 30.0
            cap2 = cv2.VideoCapture(str(vid))
            if cap2.isOpened():
                fps_guess = cap2.get(cv2.CAP_PROP_FPS) or 30.0
                cap2.release()
            png_b64, frame_idx_used, skip_reason = annotate_impact(
                str(vid),
                kpts,
                payload.get("posture_criteria", []),
                stroke_label=payload.get("stroke", {}).get("label", ""),
                pose_detection_rate=det,
                posture_evaluator=lambda kw: posture_score(kw, smooth_window=5),
                fps=fps_guess,
            )
            payload["annotated_impact_png_base64"] = png_b64
            payload["best_frame_index"] = int(frame_idx_used)
            payload["annotation_skip_reason"] = skip_reason
        except Exception as e:
            payload["annotated_impact_png_base64"] = None
            payload["best_frame_index"] = -1
            payload["annotation_skip_reason"] = f"annotation error: {type(e).__name__}: {e}"

    sp = od / f"{stem}_score.json"
    sp.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"[ok] wrote {sp}")
    print(f"[axes] evaluated={payload['axes_evaluated']} dropped={list(payload['axes_dropped'].keys())}")
    print(json.dumps({
        "stroke": payload["stroke"]["label"], "conf": round(payload["stroke"]["top1_confidence"], 3),
        "posture": payload["posture_stars"], "speed": payload["speed_stars"], "step": payload["step_stars"],
        "n_tips": len(payload["coaching_tips"]),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
