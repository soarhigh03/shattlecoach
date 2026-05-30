# inference/

ML / on-device optimization workspace for Shattlecoach. **Owner: Donghwi Moon (ML lead).**

This sibling folder lives alongside `frontend/` so it can hold non-Flutter artifacts (PyTorch, scripts, datasets, exported TFLite files) without polluting the Flutter project's dependency tree.

## Expected layout

```
inference/
├── data/                    # self-collected dataset (gitignored — too large)
│   ├── raw_clips/           # original 5s MP4 recordings
│   ├── poses/               # extracted MoveNet keypoint sequences (.npz)
│   └── labels/              # per-clip 5-bit binary labels per stroke
├── training/
│   ├── stgcn/               # slim ST-GCN reference (adapted from mmaction2)
│   ├── train.py
│   ├── eval.py
│   └── configs/
├── optimization/
│   ├── ptq_int8.py          # post-training INT8 quantization (TFLite)
│   ├── prune.py             # magnitude pruning (50% / 70% sparsity ablation)
│   ├── qat.py               # fallback if PTQ collapses
│   └── benchmark.py         # latency on Pixel 7 / iPhone 15
├── export/
│   ├── pt_to_onnx.py
│   ├── onnx_to_tflite.py    # via onnx2tf
│   └── parity_check.py      # cosine sim > 0.99 between FP32 PyTorch / TFLite
└── artifacts/               # FINAL .tflite models — copied into frontend/assets/models/
    ├── stgcn_fp32.tflite    # ~1.2 MB baseline
    ├── stgcn_int8.tflite    # ~0.3 MB target
    └── thresholds.json      # per-criterion 0/1/2 calibration thresholds
```

## Hand-off contract with `frontend/`

The Flutter side only needs:

1. A `.tflite` model file (placed in `frontend/assets/models/`).
2. Input shape: `[1, 150, 17, 3]` (batch, frames, joints, (x,y,conf)).
3. Output: `[1, 4, 5]` logits (4 strokes × 5 criteria).
4. `thresholds.json` for the 0/1/2 rating mapping.

The Dart side will not reimplement training or quantization logic — it consumes finished artifacts.
