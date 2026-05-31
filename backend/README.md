# backend/ — ShattleCoach ML scoring pipeline

On-device badminton form-scoring backend (ML lead: Donghwi). Self-contained:
pose extraction → stroke handling → rule-based form scoring → 3-axis stars →
per-stroke axis filter → annotated impact frame → coaching tips.

## Layout
```
backend/
├── scripts/
│   ├── score_server.py        # Flask /score + /health (wraps score_clip)
│   ├── quick_demo.py          # single-clip CLI wrapper
│   ├── rule_based_scorer.py   # 5 posture criteria (C1–C5), geometric
│   ├── score_swing_speed.py   # swing-speed stars vs BST percentile
│   ├── score_step.py          # footwork stars vs BST percentile
│   ├── extract_pose.py        # MediaPipe → 17 COCO keypoints
│   ├── annotate_frame.py      # draws corrections on the user's impact frame
│   ├── stroke_axes.json       # per-stroke relevant/forbidden axes (guardrail)
│   ├── prep_donghwi_clips.py  # normalize raw clips + train/test split
│   └── baseline_eval.py       # batch-eval the held-out test split
├── experiments/
│   ├── scorer_baseline/stgcn.py            # ST-GCN model definition
│   ├── stroke_classifier_bst/bst_loader.py # POSTER_CLASSES, T_TARGET=32
│   └── stroke_classifier_bst_v3/           # trained artifacts the pipeline loads
│       ├── checkpoint.pt, temperature.json, ood_mahalanobis.npz,
│       └── rule_calibration.json, swing_speed_percentiles.npz, step_percentiles.npz
├── artifacts/                 # handoff to frontend (models + thresholds)
│   ├── scorer_v3.onnx, movenet_lightning_int8.tflite
│   └── *.json (stroke_axes, temperature, rule_calibration, ood, bst percentiles)
└── requirements.txt
```

## Run
```powershell
# from repo root, with a venv that has requirements.txt installed:
python backend/scripts/quick_demo.py --video <a_5s_side_view_swing.mp4>
# PC-server mode (LLM optional via GROQ_API_KEY env var):
python backend/scripts/score_server.py --port 8765
```

## Notes
- Model input is resampled to **T=32** frames; clip duration is not critical as long
  as one full stroke (prep→impact→follow) is captured.
- The ST-GCN stroke **classifier OOD-rejects real phone clips** (measured 35/35 on test
  clips); the app design has the **user pick the stroke**, so scoring does not depend on it.
- No secrets in this folder. Set `GROQ_API_KEY` via environment for LLM coaching.
