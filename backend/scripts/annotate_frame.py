"""Reusable annotation helpers for impact-frame visualization.

Used by experiments/demo_v4/score_clip.py to embed annotated PNG (base64) in
the score JSON, and by scripts/prototype_annotate.py for standalone preview.

Public API:
  find_impact_frame(kpts) -> (frame_idx, wrist_idx)
  pick_best_frame(kpts, posture_evaluator, fps=30) -> (frame_idx, pass_count)
  criteria_to_corrections(failed_criteria, kpts_at_impact, wrist_idx) -> list[dict]
  draw_annotations_pil(img_bgr, kpts, corrections) -> np.ndarray (annotated BGR)
  encode_png_base64(img_bgr) -> str
"""
from __future__ import annotations
import base64
import math
from typing import Optional

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

COCO_NAMES = [
    "nose", "left_eye", "right_eye", "left_ear", "right_ear",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
    "left_wrist", "right_wrist", "left_hip", "right_hip",
    "left_knee", "right_knee", "left_ankle", "right_ankle",
]
IDX = {n: i for i, n in enumerate(COCO_NAMES)}

FONT_PATH = "C:/Windows/Fonts/malgun.ttf"


def _edge_trim(n: int) -> tuple[int, int]:
    """Valid [lo, hi) after excluding first/last ~12% of frames (min 2). (D4.)"""
    m = max(2, (n * 12) // 100)
    return (m, n - m) if (n - m) > m else (0, n)


def find_impact_frame(kpts: np.ndarray) -> tuple[int, int]:
    """Returns (frame_idx, wrist_idx) of peak wrist linear velocity.

    D4 (review round 1): the racket-hand wrist (higher mean confidence) is used,
    the speed profile is smoothed (3-tap moving average), and the GLOBAL maximum
    is taken within an edge-trimmed range — so start-of-clip jitter / the first
    minor peak is no longer mistaken for the impact."""
    lconf = kpts[:, IDX["left_wrist"], 2].mean()
    rconf = kpts[:, IDX["right_wrist"], 2].mean()
    wrist_idx = IDX["right_wrist"] if rconf >= lconf else IDX["left_wrist"]
    wrist_xy = kpts[:, wrist_idx, :2]
    speeds = np.linalg.norm(np.diff(wrist_xy, axis=0), axis=1)
    if speeds.size == 0:
        return 0, wrist_idx
    if speeds.size >= 3:
        speeds = np.convolve(speeds, np.ones(3) / 3.0, mode="same")
    lo, hi = _edge_trim(int(speeds.size))
    return lo + int(np.argmax(speeds[lo:hi])), wrist_idx


def _find_swing_peaks(kpts: np.ndarray, wrist_idx: int, min_distance: int = 15) -> list[int]:
    """Find local maxima in wrist velocity. Returns frame indices sorted by peak height."""
    wrist_xy = kpts[:, wrist_idx, :2]
    diffs = np.diff(wrist_xy, axis=0)
    speeds = np.linalg.norm(diffs, axis=1)
    if speeds.size == 0:
        return []
    if speeds.size >= 3:
        speeds = np.convolve(speeds, np.ones(3) / 3.0, mode="same")
    threshold = float(np.percentile(speeds, 75))
    lo, hi = _edge_trim(int(speeds.size))  # D4: ignore start/end noise
    peaks: list[int] = []
    for i in range(max(1, lo), min(len(speeds) - 1, hi)):
        if speeds[i] > threshold and speeds[i] >= speeds[i - 1] and speeds[i] >= speeds[i + 1]:
            if not peaks or i - peaks[-1] >= min_distance:
                peaks.append(i)
    if not peaks:
        peaks = [lo + int(np.argmax(speeds[lo:hi]))]
    peaks.sort(key=lambda i: -speeds[i])
    return peaks


def pick_best_frame(
    kpts: np.ndarray,
    posture_evaluator,
    fps: float = 30.0,
    window_seconds: float = 0.5,
) -> tuple[int, int, int]:
    """Pick the swing peak with the highest posture pass count.

    posture_evaluator(kpts_window) -> dict with 'criteria' list (each having 'pass' bool).
    Returns (best_frame_idx, pass_count, wrist_idx).
    Falls back to overall peak if multiple swings can't be evaluated.
    """
    lconf = kpts[:, IDX["left_wrist"], 2].mean()
    rconf = kpts[:, IDX["right_wrist"], 2].mean()
    wrist_idx = IDX["right_wrist"] if rconf >= lconf else IDX["left_wrist"]
    peaks = _find_swing_peaks(kpts, wrist_idx)
    if len(peaks) <= 1:
        peak, _ = find_impact_frame(kpts)
        return peak, -1, wrist_idx
    window = max(int(window_seconds * fps), 4)
    best = (peaks[0], -1)
    for p in peaks:
        start = max(0, p - window); end = min(kpts.shape[0], p + window + 1)
        try:
            result = posture_evaluator(kpts[start:end])
            pc = sum(1 for c in result.get("criteria", []) if c.get("pass") is True)
        except Exception:
            pc = -1
        if pc > best[1]:
            best = (p, pc)
    return best[0], best[1], wrist_idx


def criteria_to_corrections(
    failed: list[dict],
    kpts_at_impact: np.ndarray,
    wrist_idx: int,
) -> list[dict]:
    """Map failed posture criteria to visual corrections (joint + direction + label)."""
    out: list[dict] = []
    for c in failed:
        name = c.get("name", "")
        meas = c.get("measurement")
        thr = c.get("threshold")
        if meas is None or thr is None:
            continue
        if name == "peak_wrist_above_shoulder":
            out.append({
                "joint": COCO_NAMES[wrist_idx],
                "direction": (0, -120),
                "label_ko": "손목을 어깨 위로 ↑",
            })
        elif name == "elbow_extension_>=160deg":
            elbow = IDX["right_elbow" if wrist_idx == IDX["right_wrist"] else "left_elbow"]
            wrist_xy = kpts_at_impact[wrist_idx, :2]
            ekp = kpts_at_impact[elbow, :2]
            v = wrist_xy - ekp
            n = float(np.linalg.norm(v)) + 1e-6
            v = (v / n) * 100
            out.append({
                "joint": COCO_NAMES[elbow],
                "direction": (int(v[0]), int(v[1])),
                "label_ko": f"팔꿈치 더 펴기 ({meas:.0f}° → 160°+)",
            })
        elif name == "hip_rotation_>=20deg":
            out.append({"joint": "right_hip", "direction": (90, 0),
                        "label_ko": "허리 회전을 더 크게 →"})
        elif name == "knees_bent_at_prep":
            out.append({"joint": "right_knee", "direction": (0, 90),
                        "label_ko": "무릎을 더 굽히기 ↓"})
            out.append({"joint": "left_knee", "direction": (0, 90), "label_ko": ""})
    return out


def _player_scale(kpts: np.ndarray, img_h: int) -> float:
    """D5: scale markers/labels to the player's on-screen size. Full-court shots
    (small player) get bigger relative markers so annotations stay legible."""
    vis = kpts[kpts[:, 2] > 0.2]
    if vis.shape[0] >= 2:
        bbox_h = float(vis[:, 1].max() - vis[:, 1].min())
    else:
        bbox_h = img_h * 0.5
    # reference player height ~420px → scale 1.0; clamp so it never vanishes/overflows
    return float(np.clip(bbox_h / 420.0, 0.55, 2.4))


def draw_annotations_pil(
    img_bgr: np.ndarray,
    kpts: np.ndarray,
    corrections: list[dict],
    stroke_label: str = "",
) -> np.ndarray:
    img_rgb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)
    pil = Image.fromarray(img_rgb)
    d = ImageDraw.Draw(pil)
    s = _player_scale(kpts, pil.height)
    r = max(10, int(28 * s)); lw = max(3, int(7 * s)); ah = max(10, int(22 * s))
    font_label = ImageFont.truetype(FONT_PATH, max(15, int(26 * s)))
    font_title = ImageFont.truetype(FONT_PATH, 30)
    for c in corrections:
        joint = c["joint"]; dx, dy = c["direction"]; label = c["label_ko"]
        if joint not in IDX:
            continue
        x, y, conf = kpts[IDX[joint]]
        if conf < 0.2:
            continue
        cx, cy = int(x), int(y)
        dx, dy = int(dx * s), int(dy * s)  # scale the correction vector too
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(230, 40, 40), width=max(3, int(5 * s)))
        if dx != 0 or dy != 0:
            ex, ey = cx + dx, cy + dy
            d.line([(cx, cy), (ex, ey)], fill=(255, 200, 0), width=lw)
            ang = math.atan2(dy, dx)
            for off in (-0.4, 0.4):
                hx = ex - ah * math.cos(ang + off)
                hy = ey - ah * math.sin(ang + off)
                d.line([(ex, ey), (hx, hy)], fill=(255, 200, 0), width=lw)
        if label:
            bbox = d.textbbox((0, 0), label, font=font_label)
            tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
            tx = int(min(max(8, cx - tw // 2), pil.width - tw - 8))
            ty = int(min(pil.height - th - 12, cy + r + 8))
            # D5: solid background box for contrast against busy court backgrounds
            d.rectangle([tx - 6, ty - 4, tx + tw + 6, ty + th + 8], fill=(20, 20, 20))
            d.text((tx, ty), label, font=font_label, fill=(255, 90, 80))
    d.rectangle([(0, 0), (pil.width, 50)], fill=(180, 30, 30))
    title = "임팩트 자세 — 빨간 부분 수정"
    if stroke_label:
        title += f"  ({stroke_label})"
    d.text((16, 8), title, font=font_title, fill=(255, 255, 255))
    return cv2.cvtColor(np.array(pil), cv2.COLOR_RGB2BGR)


def encode_png_base64(img_bgr: np.ndarray) -> str:
    ok, buf = cv2.imencode(".png", img_bgr)
    if not ok:
        raise RuntimeError("cv2.imencode PNG failed")
    return base64.b64encode(buf.tobytes()).decode("ascii")


def annotate_impact(
    video_path: str,
    kpts: np.ndarray,
    posture_criteria: list[dict],
    stroke_label: str = "",
    pose_detection_rate: float = 1.0,
    posture_evaluator=None,
    fps: float = 30.0,
) -> tuple[Optional[str], int, Optional[str]]:
    """End-to-end: pick best frame, read it, annotate failed criteria, return base64 PNG.

    Returns (base64_png, frame_idx, skip_reason_or_None).
    """
    if pose_detection_rate < 0.5:
        return None, -1, f"pose detection {pose_detection_rate*100:.0f}% — frame too noisy to annotate"
    failed = [c for c in posture_criteria if c.get("pass") is False]
    if posture_evaluator is not None:
        try:
            frame_idx, _, wrist_idx = pick_best_frame(kpts, posture_evaluator, fps=fps)
        except Exception:
            frame_idx, wrist_idx = find_impact_frame(kpts)
    else:
        frame_idx, wrist_idx = find_impact_frame(kpts)
    cap = cv2.VideoCapture(str(video_path))
    cap.set(cv2.CAP_PROP_POS_FRAMES, int(frame_idx))
    ok, frame = cap.read()
    cap.release()
    if not ok or frame is None:
        return None, frame_idx, f"could not read frame {frame_idx} from video"
    corrections = criteria_to_corrections(failed, kpts[frame_idx], wrist_idx)
    annotated = draw_annotations_pil(frame, kpts[frame_idx], corrections, stroke_label=stroke_label)
    return encode_png_base64(annotated), frame_idx, None
