# Shattlecoach 🏸

On-device badminton form coach. SNU Mobile Computing and Its Applications
(4190.406B), Spring 2026 mini-project.

Record a 5-second swing, get a per-criterion form score, an annotated impact
frame, and a short Korean coaching note — all computed on the phone, no server.

---

## Layout

```
shattlecoach/
├── frontend/    # Flutter app (iOS + Android). Owner: Eunwoo Choi.
├── inference/   # ML workspace: training, quantization, ONNX/TFLite export,
│                # final .tflite artifacts handed off to frontend/assets/models/.
│                # Owner: Donghwi Moon.
├── supabase/    # Postgres schema + migrations (auth + RLS).
└── README.md
```

ML hand-off contract and per-stage details: `inference/README.md`.

---

## Quick start (for graders)

```bash
cd frontend
cp .env.example .env       # replace with the .env shipped in the ETL bundle
flutter pub get
flutter run                # Android device or emulator recommended
```

- A pre-signed `app-release.apk` is included in the ETL submission for
  install-and-run grading.
- Demo numbers below are measured on a **Galaxy S21** (Android 14, ARM64).
- Google OAuth needs the build's SHA-1 registered on our Cloud Console; if you
  hit a `sign_in_failed` error, use the bundled APK + `.env` from the ETL
  submission, or email us your debug SHA-1 and we'll allow-list it.

> `SUPABASE_ANON_KEY` is designed to be public (RLS in `supabase/schema.sql`
> enforces real authorization). Secrets like the Groq key are mailed out of
> band and never committed.

---

## Stack

- **Flutter 3.44 / Dart 3.12** (stable)
- **State / routing**: Riverpod, go_router (5-tab `ShellRoute`)
- **Backend**: Supabase (Postgres + Auth + RLS)
- **Auth**: Google OAuth via Supabase (native ID-token exchange)
- **On-device ML**: MoveNet INT8 (TFLite) → rule-based 4-criterion posture
  scoring + BST-percentile speed/footwork stars
- **Optional LLM**: Groq `llama-3.1-8b-instant` for paragraph smoothing only
  (guard-railed; never adds new advice)
- **Bundle ID**: `com.mca.shattlecoach`
- **Permissions**: camera, notifications (requested behind onboarding primers)

---

## App flow

**Onboarding** — logo intro → Google sign-in → intro → profile (name, dominant
hand) → 5-tab home.

| Tab | Purpose |
|---|---|
| **AI Coach** | Pick a stroke (high clear / short serve / forehand drive) → trim video → on-device analysis → stars + radar + annotated impact frame + coaching text |
| **Report** | Cumulative progress, weak-criterion heatmap |
| **Sessions** | Sign up for / cancel club practice slots |
| **Equipment** | Group-buy board (sign-ups only; payment off-app) |
| **Settings** | Account, exec registration, sign-out & delete, version, licenses |

---

## Models & optimization (assignment evaluation criterion)

### Models in the pipeline

| Stage | Model / method | Notes |
|---|---|---|
| 1. Pose estimation | **MoveNet Lightning, TFLite INT8** | 17 COCO keypoints. Pretrained INT8 model (~2.9 MB) — the heaviest runtime component. |
| 2. Stroke selection | User picks before recording | A trained ST-GCN classifier exists in `inference/` but is bypassed at runtime because real phone clips fall OOD too often. |
| 3. Posture scoring | **Rule-based, 4 criteria** (impact point, elbow, hip rotation, knee) | Per-stroke geometric thresholds map to 0/1/2. No NN. |
| 4. Speed / footwork stars | **BST percentile lookup** | 1–5★ from self-collected percentile tables. |
| 5. Impact annotation | Overlay correction cues on the impact frame | Per-stroke Korean labels. |
| 6. Coaching text | **Deterministic rulebook** + optional LLM smoothing | LLM stitches selected rulebook sentences; guard-rails forbid new content. |

### Optimization experiments — before / after

The spec requires **pruning or quantization with marginal accuracy drop**.
We deploy a pretrained INT8 MoveNet (the dominant compute) and ran three
experiments on our own ST-GCN classifier and pipeline.

#### ① Data augmentation retrain — ST-GCN V2 → V3 (kept)

Same architecture (268,618 params), 2.4× larger training set
(ShuttleSet + BadmintonDB + horizontal flip).

| Metric | V2 | V3 | Δ |
|---|---:|---:|---:|
| Training clips | 4,510 | 10,856 | 2.4× |
| Test Top-1 accuracy | 87.11% | **89.58%** | **+2.47 pp** |
| `forehand_drive` recall | 0.726 | 0.800 | +7.4 pp |
| `forehand_drive` F1 | 0.787 | 0.826 | +0.039 |

Source: `inference/experiments/stroke_classifier_bst{,_v3}/eval.json`.

#### ② INT8 quantization — attempted, rolled back

Static QDQ INT8 quantization of the trained FP32 ST-GCN.

| Metric | FP32 | INT8 | Δ |
|---|---:|---:|---:|
| Model size | 1,086 KB | 335 KB | **3.24× smaller** |
| Test Top-1 accuracy | 89.58% | 68.69% | **−20.89 pp** |

Decision: accuracy loss far above the "marginal" bar, so we **discarded the
INT8 artifact and kept the FP32 model**. The shipped artifact hash matches the
FP32 baseline. Source: `inference/experiments/mobile_conversion_v3/results.json`.

#### ③ On-device inference parallelization (kept)

ONNX export + 3-isolate worker pool for the pose-extraction stage (output
identical to the single-worker run; only latency changes).

| Metric | Before | After | Δ |
|---|---:|---:|---:|
| 5 s clip latency (Galaxy S21) | 51 s | **24 s** | **~2.1× faster** |

Source: `inference/HANDOFF.md`.

#### Summary

| | Effect | Shipped? |
|---|---|---|
| Data augmentation (V2 → V3) | +2.47 pp accuracy | ✅ |
| INT8 quantization (FP32 → INT8) | 3.24× smaller / −20.89 pp accuracy | ❌ (rolled back to protect accuracy) |
| Inference parallelization (1 → 3 isolates) | 51 s → 24 s (2.1×) | ✅ |

One-line takeaway: augmentation raised accuracy, quantization was rejected to
preserve accuracy, and parallelization cut latency.

---

## Contributors

- **Eunwoo Choi** — Flutter app (UI, routing, auth, integration, builds) & Data Collection
- **Donghwi Moon** — On-device ML (training/eval, quantization & ONNX
  experiments, scoring + coaching) & Data Collection
