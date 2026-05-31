"""V3-E1. One-command demo wrapper.

Usage:
    python scripts/quick_demo.py --video PATH

Runs:
  1. Pose extraction (MediaPipe)
  2. V3 score (BST classifier + temperature + Mahalanobis OOD + rule scorer)
  3. Creates a single results PNG (overlay strip + key numbers)
  4. Opens the results JSON in the default file viewer

Outputs:
  experiments/demo_v3/output/<clip>_score.json
  experiments/demo_v3/output/<clip>_overlay/frame_*.png
  experiments/demo_v3/output/<clip>_dashboard.png      <- one-image summary

"""
from __future__ import annotations
import argparse
import json
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
PY = sys.executable
SCORE = ROOT / "experiments" / "demo_v4" / "score_clip.py"  # V4: 3-axis posture/speed/step


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", required=True)
    ap.add_argument("--open", action="store_true", help="Open the result dashboard PNG when done")
    args = ap.parse_args()

    vid = Path(args.video)
    if not vid.exists():
        print(f"ERROR: video not found: {vid}"); sys.exit(2)

    print(f"[quick_demo] running V3 pipeline on {vid.name} ...")
    cmd = [PY, str(SCORE), "--video", str(vid)]
    proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if proc.returncode != 0:
        print(f"V3 pipeline failed (exit {proc.returncode}):\n{proc.stderr[-800:]}"); sys.exit(3)

    out_dir = ROOT / "experiments" / "demo_v4" / "output"
    score_path = out_dir / f"{vid.stem}_score.json"
    if not score_path.exists():
        print(f"ERROR: no score JSON at {score_path}"); sys.exit(4)
    s = json.loads(score_path.read_text(encoding="utf-8"))

    # Build a single dashboard PNG
    overlay_dir = out_dir / f"{vid.stem}_overlay"
    overlays = sorted(overlay_dir.glob("frame_*.png")) if overlay_dir.exists() else []
    if overlays:
        imgs = [cv2.imread(str(p)) for p in overlays]
        # Resize each to width 220
        target_w = 220
        scale = target_w / imgs[0].shape[1]
        imgs = [cv2.resize(im, (target_w, int(im.shape[0] * scale))) for im in imgs]
        H = imgs[0].shape[0]
        pad = 4
        strip = np.full((H, len(imgs) * (target_w + pad) + pad, 3), 230, dtype=np.uint8)
        for i, im in enumerate(imgs):
            strip[:, pad + i * (target_w + pad):pad + i * (target_w + pad) + target_w] = im
    else:
        strip = np.full((180, 1200, 3), 240, dtype=np.uint8)
        cv2.putText(strip, "(no overlay frames available)", (40, 90),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (100, 100, 100), 1)

    # Text panel with score summary
    text_h = 360
    text_panel = np.full((text_h, strip.shape[1], 3), 252, dtype=np.uint8)
    y = 30
    cv2.putText(text_panel, f"ShattleCoach result -- {vid.name}", (16, y),
                cv2.FONT_HERSHEY_SIMPLEX, 0.7, (20, 20, 20), 2); y += 30
    cv2.line(text_panel, (0, y - 4), (text_panel.shape[1], y - 4), (180, 180, 180), 1)

    status = s.get("status", "?")
    if status == "REJECTED_LOW_POSE_DETECTION":
        cv2.putText(text_panel, f"STATUS: POSE DETECTION FAILED (det_rate {s['pose_detection_rate']:.2f} < 0.50)",
                    (16, y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (180, 30, 30), 2); y += 30
        cv2.putText(text_panel, s.get("message_ko", "")[:60], (16, y),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.4, (40, 40, 40), 1); y += 20
    else:
        # V4 score JSON shape: top-level posture_stars/speed_stars/step_stars; stroke with softmax + is_ood
        stroke = s["stroke"]
        is_ood = stroke.get("is_ood", False)
        col = (160, 30, 30) if is_ood else (30, 130, 30)
        cv2.putText(text_panel, f"Pose detection: {s['pose_detection_rate']:.2f}", (16, y),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (40, 40, 40), 1); y += 22
        cv2.putText(text_panel, f"Stroke: {stroke['label']}   (conf {stroke['top1_confidence']:.2f})",
                    (16, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, col, 1); y += 22
        cv2.putText(text_panel, f"  softmax: " + ", ".join(f"{k}={v:.2f}" for k, v in stroke['softmax_3class'].items()),
                    (16, y), cv2.FONT_HERSHEY_SIMPLEX, 0.42, (50, 50, 50), 1); y += 28

        # 3-axis stars
        ps = s.get("posture_stars"); sps = s.get("speed_stars"); sts = s.get("step_stars")
        cv2.putText(text_panel, f"Posture: {ps}/5    Speed: {sps}/5    Step: {sts}/5",
                    (16, y), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (20, 20, 80), 2); y += 30

        cv2.putText(text_panel, "Criteria (rule-based, continuous measurements):", (16, y),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.42, (20, 20, 20), 1); y += 20
        for c in s.get("posture_criteria", []):
            if c.get("pass") is None:
                badge = "[N/A]"; col2 = (130, 130, 130); val = "(measurement unavailable)"
            elif c["pass"]:
                badge = "[PASS]"; col2 = (30, 130, 30); val = f"{c['measurement']:.2f} {c['unit']} (thr {c['threshold']:.2f})"
            else:
                badge = "[FAIL]"; col2 = (160, 30, 30); val = f"{c['measurement']:.2f} {c['unit']} (thr {c['threshold']:.2f})"
            cv2.putText(text_panel, f"  {badge} {c['name']}: {val}", (16, y),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.38, col2, 1); y += 17

        if s.get("coaching_tips"):
            y += 4
            cv2.putText(text_panel, "Coaching tips (top 3):", (16, y),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.42, (20, 20, 20), 1); y += 18
            for tip in s["coaching_tips"][:3]:
                cv2.putText(text_panel, "  - " + (tip.get("tip_en") or "")[:80], (16, y),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.34, (40, 40, 40), 1); y += 15

    dash = np.concatenate([strip, np.full((6, strip.shape[1], 3), 220, dtype=np.uint8), text_panel], axis=0)
    dash_path = out_dir / f"{vid.stem}_dashboard.png"
    cv2.imwrite(str(dash_path), dash)
    print(f"[ok] score JSON:   {score_path}")
    print(f"[ok] dashboard:    {dash_path}")
    print()
    print("--- summary ---")
    print(f"  status: {status}")
    if status == "OK":
        print(f"  stroke: {s['stroke']['label']}  (conf {s['stroke']['top1_confidence']:.2f}, is_ood={s['stroke'].get('is_ood', '?')})")
        print(f"  posture: {s.get('posture_stars')}/5  speed: {s.get('speed_stars')}/5  step: {s.get('step_stars')}/5")
        for tip in s.get('coaching_tips', []):
            print(f"  TIP[{tip.get('axis','?')}]: {tip['tip_ko']}")
    else:
        print(f"  status: {status}  message: {s.get('message_ko', '(no message)')}")

    if args.open:
        try:
            import os
            os.startfile(str(dash_path))
        except Exception as e:
            print(f"[warn] could not open file: {e}")


if __name__ == "__main__":
    main()
