# AAC Gaze Tracking

Eye-gaze tracking pipeline for an Augmentative and Alternative Communication
(AAC) system. Built as the MSc group project for Maastricht University,
Group 10. The pipeline drives a Cboard-based on-screen keyboard by estimating
where a non-speaking user is looking, using only a standard laptop webcam.

## Result

**1.50° mean angular error** across 9 calibration-grid targets on a single
healthy user at ~60 cm viewing distance — meets the project plan's <2°
threshold. Full per-target breakdown, failure-mode analysis and library
comparison in [RESULTS.md](RESULTS.md).

| | Value |
|---|---|
| Library | EyeTrax 0.4.0 (Ridge regressor) |
| Post-processing | 13-point calibration → affine bias → EMA (α=0.3) → pose-gated confidence |
| Mean angular error | 1.50° |
| Mean precision (σ at fixation) | 32 px |
| Throughput | 113 fps on MacBook Air M4 |
| Face detection rate | 100 % |

## Repository contents

| File | Role |
|---|---|
| `gaze_test_eyetrax.py` | End-to-end benchmark: calibration → bias → evaluation → free tracking |
| `head_pose.py` | MediaPipe Face Mesh + `cv2.solvePnP` head-pose estimator (6-DoF) |
| `requirements.txt` | Pinned Python dependencies |
| `RESULTS.md` | Full benchmark writeup, library comparison, negative results |
| `Group_10_Project_Plan.pdf` | Original project plan |

## Setup

Requires **Python 3.11.x** — MediaPipe 0.10.x does not support 3.12+ on
macOS ARM64.

```bash
python3.11 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

MediaPipe will download its FaceLandmarker model (~4 MB) into
`~/.cache/eyetrax/mediapipe/face_landmarker.task` on first run.

## Running the benchmark

```bash
python gaze_test_eyetrax.py
```

Three phases, driven by a pygame window:

1. **Calibration** (blue dots) — stare at each of 13 points for ~1.8 s.
2. **Bias measurement** (green dots) — 5 anchor points, ~1.2 s each, fits
   the per-axis affine correction.
3. **Evaluation** (red dots) — 9 targets, 2 s each, per-target accuracy
   and precision are logged to `metrics_eyetrax.json` + `.csv`.
4. **Free tracking** — live gaze overlay. Press Q to save and quit. A
   green ring means the pose gate is open; an orange ring means the
   current head pose is outside the calibration distribution and the
   prediction is marked low-confidence (`conf < 0.5`).

## How pose gating works

After calibration, the 6-dim head-pose vector (yaw, pitch, roll, tx, ty,
tz from `cv2.solvePnP` on 6 MediaPipe landmarks) has per-dim mean/std
computed, with each std floored at `[0.05 rad, 0.05 rad, 0.05 rad, 5 mm,
5 mm, 10 mm]` to prevent a pathologically narrow gate. At runtime,

```
z = sqrt(mean(((p − μ) / σ)²))
conf = max(0, 1 − z / 3.0)
```

`conf` is included in each CSV row and surfaced live in the free-tracking
overlay. Downstream Cboard integration can drop dwell progress when
`conf < 0.5`.

Head-pose features were also tested as direct inputs to the Ridge
regressor; they regressed accuracy catastrophically. See RESULTS.md
§"Head-pose compensation — negative result" for the full diagnosis —
feature-scale mismatch on a linear regressor.

## Authors

Maastricht University MSc Group 10: Mathijs, Dan, Gabriel, Vasile.
