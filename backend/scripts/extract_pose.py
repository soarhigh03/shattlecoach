"""Extract 17 COCO-keypoint skeleton from a video clip.

US-006 deliverable. Two backends:
  - mediapipe (default): BlazePose Full, remapped from 33 BlazePose kpts to 17 COCO kpts.
  - movenet: MoveNet Thunder INT8 TFLite from local file (skip TFHub network fetch on Windows).

Usage:
    python scripts/extract_pose.py --video data/samples/swing.mp4 \
        --out experiments/pose_extraction/swing_kpts.npz \
        --overlay experiments/pose_extraction/sample_overlay.png \
        --backend mediapipe
"""
from __future__ import annotations
import argparse
import json
import os
import time
from pathlib import Path

import cv2
import numpy as np


COCO_17 = [
    "nose", "left_eye", "right_eye", "left_ear", "right_ear",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
    "left_wrist", "right_wrist", "left_hip", "right_hip",
    "left_knee", "right_knee", "left_ankle", "right_ankle",
]

# MediaPipe BlazePose landmark indices: see
# https://developers.google.com/mediapipe/solutions/vision/pose_landmarker
# We map 33 BlazePose -> 17 COCO. For the face block, BlazePose has nose=0,
# left_eye_inner=1, left_eye=2, ..., right_ear=8. COCO uses nose, l/r eye,
# l/r ear, so we pick BlazePose 0,2,5,7,8.
BLAZEPOSE_TO_COCO = {
    "nose": 0,
    "left_eye": 2,
    "right_eye": 5,
    "left_ear": 7,
    "right_ear": 8,
    "left_shoulder": 11,
    "right_shoulder": 12,
    "left_elbow": 13,
    "right_elbow": 14,
    "left_wrist": 15,
    "right_wrist": 16,
    "left_hip": 23,
    "right_hip": 24,
    "left_knee": 25,
    "right_knee": 26,
    "left_ankle": 27,
    "right_ankle": 28,
}

SKELETON_EDGES = [
    (5, 7), (7, 9), (6, 8), (8, 10),
    (11, 13), (13, 15), (12, 14), (14, 16),
    (5, 6), (11, 12), (5, 11), (6, 12),
    (0, 1), (0, 2), (1, 3), (2, 4),
]


def _draw_skeleton(frame: np.ndarray, kpts: np.ndarray, conf_thr: float = 0.3) -> np.ndarray:
    """kpts: shape (17, 3) — (x_px, y_px, conf). Returns BGR frame with overlay."""
    out = frame.copy()
    for a, b in SKELETON_EDGES:
        if kpts[a, 2] > conf_thr and kpts[b, 2] > conf_thr:
            pa = (int(kpts[a, 0]), int(kpts[a, 1]))
            pb = (int(kpts[b, 0]), int(kpts[b, 1]))
            cv2.line(out, pa, pb, (0, 255, 0), 2)
    for i in range(17):
        if kpts[i, 2] > conf_thr:
            p = (int(kpts[i, 0]), int(kpts[i, 1]))
            cv2.circle(out, p, 3, (0, 0, 255), -1)
    return out


def extract_mediapipe(video_path: str) -> tuple[np.ndarray, int, int]:
    """Returns (kpts [T,17,3] in pixel coords, width, height)."""
    import mediapipe as mp

    pose = mp.solutions.pose.Pose(
        static_image_mode=False,
        model_complexity=1,  # BlazePose Full
        enable_segmentation=False,
        min_detection_confidence=0.5,
        min_tracking_confidence=0.5,
    )
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise FileNotFoundError(f"Could not open video: {video_path}")
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

    all_kpts: list[np.ndarray] = []
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        res = pose.process(rgb)
        kpts17 = np.zeros((17, 3), dtype=np.float32)
        if res.pose_landmarks is not None:
            for i, name in enumerate(COCO_17):
                lm = res.pose_landmarks.landmark[BLAZEPOSE_TO_COCO[name]]
                kpts17[i, 0] = lm.x * w
                kpts17[i, 1] = lm.y * h
                kpts17[i, 2] = lm.visibility
        all_kpts.append(kpts17)
    cap.release()
    pose.close()
    return np.stack(all_kpts, axis=0), w, h


def extract_movenet(video_path: str, model_path: str) -> tuple[np.ndarray, int, int]:
    """MoveNet Thunder TFLite. Requires a local .tflite file (no network fetch)."""
    import tensorflow as tf

    interp = tf.lite.Interpreter(model_path=model_path)
    interp.allocate_tensors()
    in_det = interp.get_input_details()[0]
    out_det = interp.get_output_details()[0]
    input_size = in_det["shape"][1]  # 256 for Thunder, 192 for Lightning
    input_dtype = in_det["dtype"]

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise FileNotFoundError(f"Could not open video: {video_path}")
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

    all_kpts: list[np.ndarray] = []
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        resized = cv2.resize(rgb, (input_size, input_size))
        if input_dtype == np.uint8:
            inp = resized.astype(np.uint8)[None, ...]
        else:
            inp = (resized.astype(np.float32) / 255.0)[None, ...]
        interp.set_tensor(in_det["index"], inp)
        interp.invoke()
        out = interp.get_tensor(out_det["index"])  # shape (1,1,17,3): (y, x, conf)
        kpts17 = np.zeros((17, 3), dtype=np.float32)
        raw = out[0, 0]  # (17, 3)
        kpts17[:, 0] = raw[:, 1] * w
        kpts17[:, 1] = raw[:, 0] * h
        kpts17[:, 2] = raw[:, 2]
        all_kpts.append(kpts17)
    cap.release()
    return np.stack(all_kpts, axis=0), w, h


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", required=True, help="Path to .mp4 input clip")
    ap.add_argument("--out", required=True, help="Output .npz with kpts and meta")
    ap.add_argument(
        "--overlay",
        default=None,
        help="Optional path to write a single PNG with skeleton overlaid on the middle frame",
    )
    ap.add_argument("--backend", choices=["mediapipe", "movenet"], default="mediapipe")
    ap.add_argument(
        "--movenet-model",
        default="data/models/movenet_thunder_int8.tflite",
        help="Required if --backend movenet",
    )
    ap.add_argument("--log", default=None, help="Append run timing to this file")
    args = ap.parse_args()

    Path(os.path.dirname(args.out) or ".").mkdir(parents=True, exist_ok=True)

    t0 = time.perf_counter()
    if args.backend == "mediapipe":
        kpts, w, h = extract_mediapipe(args.video)
    else:
        if not os.path.exists(args.movenet_model):
            raise FileNotFoundError(
                f"MoveNet TFLite not found at {args.movenet_model}. "
                "Download from https://www.kaggle.com/models/google/movenet/tfLite "
                "or via tfhub_dev mirror and place it at that path."
            )
        kpts, w, h = extract_movenet(args.video, args.movenet_model)
    elapsed = time.perf_counter() - t0

    n_frames = kpts.shape[0]
    fps = n_frames / max(elapsed, 1e-9)

    np.savez(
        args.out,
        keypoints=kpts.astype(np.float32),
        width=np.int32(w),
        height=np.int32(h),
        backend=np.array([args.backend]),
        coco_names=np.array(COCO_17),
    )

    if args.overlay is not None:
        cap = cv2.VideoCapture(args.video)
        mid = n_frames // 2
        cap.set(cv2.CAP_PROP_POS_FRAMES, mid)
        ok, frame = cap.read()
        cap.release()
        if ok:
            overlaid = _draw_skeleton(frame, kpts[mid])
            Path(os.path.dirname(args.overlay) or ".").mkdir(parents=True, exist_ok=True)
            cv2.imwrite(args.overlay, overlaid)

    summary = {
        "video": args.video,
        "out": args.out,
        "backend": args.backend,
        "n_frames": int(n_frames),
        "width": int(w),
        "height": int(h),
        "elapsed_s": round(elapsed, 3),
        "fps": round(fps, 2),
    }
    print(json.dumps(summary, indent=2))
    if args.log is not None:
        Path(os.path.dirname(args.log) or ".").mkdir(parents=True, exist_ok=True)
        with open(args.log, "a", encoding="utf-8") as f:
            f.write(json.dumps(summary) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
