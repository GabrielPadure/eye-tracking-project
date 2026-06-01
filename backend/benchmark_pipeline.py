"""
Benchmark for the *live* GazePipeline (commit 3a5ec5e+) — the same algorithm
the WebSocket server + Flutter app run.

Direct A/B counterpart to gaze_test_eyetrax.py:
  - Same window size, viewing distance, screen diagonal → identical px↔°
    conversion so mean angular errors are directly comparable.
  - Same 13-point calibration grid (CALIB_MAP_PTS) and 5-anchor bias pass
    (BIAS_PTS) — imported from gaze_pipeline so they can't drift apart.
  - Same 9-target evaluation grid (EVAL_POINTS) with the same dwell times.

Differences this benchmark exercises (which the baseline does not):
  - RBF KernelRidge regressor (sklearn) replaces EyeTrax's linear Ridge.
  - Pose-aware affine bias correction.
  - Mouth-open (MAR) gating — samples are dropped during calibration when
    the user's mouth opens.

Outputs:
  metrics_pipeline.json   — summary + per-target accuracy
  metrics_pipeline.csv    — per-frame log (phase, target, gaze, blink, conf)
"""

from __future__ import annotations

import csv
import json
import math
import time
from typing import Optional

import cv2
import numpy as np
import pygame

from gaze_pipeline import (
    GazePipeline,
    CALIB_MAP_PTS,
    BIAS_PTS,
    MAR_OPEN,
)


# --- config (matched to gaze_test_eyetrax.py so numbers are comparable) ---
WINDOW_W, WINDOW_H = 1280, 800
CAM_W, CAM_H = 1280, 720
CAMERA_INDEX = 0
CALIB_DWELL_SEC = 1.8
CALIB_WARMUP_SEC = 0.4
BIAS_DWELL_SEC = 1.2
BIAS_WARMUP_SEC = 0.4
EVAL_POINTS = [
    (0.2, 0.2), (0.5, 0.2), (0.8, 0.2),
    (0.2, 0.5), (0.5, 0.5), (0.8, 0.5),
    (0.2, 0.8), (0.5, 0.8), (0.8, 0.8),
]
EVAL_HOLD_SEC = 2.0
EVAL_WARMUP_SEC = 0.6
VIEWING_DISTANCE_CM = 60.0
SCREEN_DIAG_INCHES = 15.6


# --- init ---
pygame.init()
pygame.font.init()
sw, sh = WINDOW_W, WINDOW_H
screen = pygame.display.set_mode((sw, sh))
pygame.display.set_caption("Gaze Benchmark — Pipeline (kridge + pose bias + MAR)")
font_small = pygame.font.SysFont("Arial", 22)
font_big = pygame.font.SysFont("Arial", 40, bold=True)

diag_px = math.hypot(sw, sh)
px_per_cm = diag_px / (SCREEN_DIAG_INCHES * 2.54)

pipeline = GazePipeline(window_size=(WINDOW_W, WINDOW_H))

cap = cv2.VideoCapture(CAMERA_INDEX)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, CAM_W)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, CAM_H)
print(f"Camera: {cap.get(cv2.CAP_PROP_FRAME_WIDTH):.0f}x"
      f"{cap.get(cv2.CAP_PROP_FRAME_HEIGHT):.0f}")

clock = pygame.time.Clock()

# --- metrics ---
csv_rows = []
eval_results = []
frame_times = []
face_ok = 0
mouth_skips = 0
total = 0


def txt(s, pos, color=(255, 255, 255), big=False):
    f = font_big if big else font_small
    screen.blit(f.render(s, True, color), pos)


def handle_events():
    for e in pygame.event.get():
        if e.type == pygame.QUIT:
            return False
        if e.type == pygame.KEYDOWN and e.key in (pygame.K_q, pygame.K_ESCAPE):
            return False
    return True


def grab():
    """Read one frame and extract feats/blink/pose/mar via the pipeline."""
    global total
    total += 1
    ret, frame = cap.read()
    t0 = time.perf_counter()
    if not ret:
        return None, False, None, None, 0.0
    feats, blink, pose, mar = pipeline.extract(frame)
    dt = (time.perf_counter() - t0) * 1000.0
    return feats, blink, pose, mar, dt


# =========================================================
# PHASE 1: CALIBRATION
# =========================================================
print("Phase 1: calibration — stare at each blue dot until it moves.")
running = True
for i, (fx, fy) in enumerate(CALIB_MAP_PTS):
    if not running:
        break
    tgt_px = (int(fx * sw), int(fy * sh))
    t_start = time.perf_counter()
    while time.perf_counter() - t_start < CALIB_DWELL_SEC:
        if not handle_events():
            running = False
            break
        feats, blink, pose, mar, dt = grab()
        frame_times.append(dt)

        screen.fill((0, 0, 0))
        pygame.draw.circle(screen, (100, 150, 255), tgt_px, 18)
        pygame.draw.circle(screen, (255, 255, 255), tgt_px, 6)
        remain = CALIB_DWELL_SEC - (time.perf_counter() - t_start)
        txt(f"Calibration {i+1}/{len(CALIB_MAP_PTS)}   {remain:.1f}s",
            (40, 40), big=True)

        if feats is not None:
            face_ok += 1
            mouth_open = mar is not None and mar > MAR_OPEN
            if (time.perf_counter() - t_start >= CALIB_WARMUP_SEC
                    and not blink and not mouth_open):
                pipeline.add_calibration_sample(feats, tgt_px, pose)
            elif mouth_open:
                mouth_skips += 1
                txt("(mouth open — skipping)", (40, sh - 80), (255, 200, 80))
        else:
            txt("No face detected", (40, sh - 80), (255, 80, 80))

        pygame.display.flip()
        clock.tick(60)

if not running or not pipeline.train():
    n = len(pipeline._X_calib)  # type: ignore[attr-defined]
    print(f"Not enough calibration samples ({n}), aborting.")
    pygame.quit()
    cap.release()
    pipeline.close()
    raise SystemExit(1)

print(f"Trained on {len(pipeline._X_calib)} samples. "  # type: ignore[attr-defined]
      f"Skipped {mouth_skips} mouth-open frames.")

# =========================================================
# PHASE 1b: BIAS MEASUREMENT
# =========================================================
print("Phase 1b: bias measurement — stare at each green dot briefly.")
for j, (fx, fy) in enumerate(BIAS_PTS):
    if not running:
        break
    tgt_px = (int(fx * sw), int(fy * sh))
    t_start = time.perf_counter()
    while time.perf_counter() - t_start < BIAS_DWELL_SEC:
        if not handle_events():
            running = False
            break
        feats, blink, pose, mar, dt = grab()
        frame_times.append(dt)

        screen.fill((0, 0, 0))
        pygame.draw.circle(screen, (80, 220, 120), tgt_px, 22)
        pygame.draw.circle(screen, (255, 255, 255), tgt_px, 6)
        remain = BIAS_DWELL_SEC - (time.perf_counter() - t_start)
        txt(f"Bias {j+1}/{len(BIAS_PTS)}   {remain:.1f}s", (40, 40), big=True)

        if feats is not None:
            face_ok += 1
            mouth_open = mar is not None and mar > MAR_OPEN
            if (time.perf_counter() - t_start >= BIAS_WARMUP_SEC
                    and not blink and not mouth_open):
                pipeline.add_bias_sample(feats, tgt_px, pose)

        pygame.display.flip()
        clock.tick(60)

pipeline.fit_bias()
pipeline.reset_smoothing()

# =========================================================
# PHASE 2: EVALUATION
# =========================================================
print("Phase 2: evaluation — stare at each red dot.")
for fx, fy in EVAL_POINTS:
    if not running:
        break
    tgt_px = (int(fx * sw), int(fy * sh))
    samples = []
    t_start = time.perf_counter()
    while time.perf_counter() - t_start < EVAL_HOLD_SEC:
        if not handle_events():
            running = False
            break

        # process_frame() runs the full live pipeline: regressor → pose bias
        # → EMA smoothing → confidence gate → mouth-open hold. We read it
        # inside the camera loop so timing matches the baseline benchmark.
        t0 = time.perf_counter()
        ret, frame = cap.read()
        if not ret:
            continue
        total += 1
        out = pipeline.process_frame(frame)
        dt = (time.perf_counter() - t0) * 1000.0
        frame_times.append(dt)

        screen.fill((0, 0, 0))
        pygame.draw.circle(screen, (255, 60, 60), tgt_px, 30)
        pygame.draw.circle(screen, (255, 255, 255), tgt_px, 8)

        if out is not None:
            face_ok += 1
            gx = int(out["x"] * sw)
            gy = int(out["y"] * sh)
            conf = out["confidence"]
            blink = out["blink"]
            color = (0, 255, 0) if conf >= 0.5 else (255, 170, 40)
            pygame.draw.circle(screen, color, (gx, gy), 10, 2)
            csv_rows.append([time.time(), "eval", tgt_px[0], tgt_px[1],
                             gx, gy, int(blink), dt, conf])
            if (time.perf_counter() - t_start >= EVAL_WARMUP_SEC
                    and not blink and conf >= 0.5):
                samples.append((gx, gy))

        remain = EVAL_HOLD_SEC - (time.perf_counter() - t_start)
        txt(f"Stare here — {remain:.1f}s", (40, 40), big=True)
        pygame.display.flip()
        clock.tick(60)

    if samples:
        xs = np.array([s[0] for s in samples])
        ys = np.array([s[1] for s in samples])
        mx, my = float(xs.mean()), float(ys.mean())
        acc_px = math.hypot(mx - tgt_px[0], my - tgt_px[1])
        prec_px = float(np.sqrt(np.var(xs) + np.var(ys)))
        ang = math.degrees(math.atan2(acc_px / px_per_cm, VIEWING_DISTANCE_CM))
        eval_results.append({
            "target": tgt_px, "mean_gaze": (mx, my), "n_samples": len(samples),
            "accuracy_px": acc_px, "precision_px": prec_px,
            "angular_error_deg": ang,
        })
        print(f"  {tgt_px} n={len(samples)} acc={acc_px:.1f}px "
              f"({ang:.2f}°) prec={prec_px:.1f}px")
    else:
        eval_results.append({"target": tgt_px, "n_samples": 0})

# =========================================================
# PHASE 3: FREE TRACKING
# =========================================================
print("Phase 3: free tracking — press Q to save and quit.")
while running:
    if not handle_events():
        break
    t0 = time.perf_counter()
    ret, frame = cap.read()
    if not ret:
        continue
    total += 1
    out = pipeline.process_frame(frame)
    dt = (time.perf_counter() - t0) * 1000.0
    frame_times.append(dt)

    screen.fill((0, 0, 0))
    if out is not None:
        face_ok += 1
        gx = int(out["x"] * sw)
        gy = int(out["y"] * sh)
        conf = out["confidence"]
        blink = out["blink"]
        color = (0, 255, 0) if conf >= 0.5 else (255, 170, 40)
        pygame.draw.circle(screen, color, (gx, gy), 14, 3)
        gate = "OK" if conf >= 0.5 else "LOW"
        txt(f"gaze=({gx},{gy})  blink={blink}  "
            f"conf={conf:.2f}  [{gate}]", (40, 40))
        csv_rows.append([time.time(), "free", -1, -1, gx, gy,
                         int(blink), dt, conf])
    else:
        txt("No face detected", (40, 40), (255, 80, 80))
    txt("Press Q to finish", (40, sh - 40))
    pygame.display.flip()
    clock.tick(60)

cap.release()
pygame.quit()
pipeline.close()

# =========================================================
# SAVE METRICS
# =========================================================
det_rate = face_ok / max(1, total)
avg_ms = float(np.mean(frame_times)) if frame_times else 0.0
fps = 1000.0 / avg_ms if avg_ms > 0 else 0.0

valid = [r for r in eval_results if r.get("n_samples", 0) > 0]
if valid:
    mean_acc = float(np.mean([r["accuracy_px"] for r in valid]))
    mean_prec = float(np.mean([r["precision_px"] for r in valid]))
    mean_ang = float(np.mean([r["angular_error_deg"] for r in valid]))
else:
    mean_acc = mean_prec = mean_ang = float("nan")

summary = {
    "library": (f"GazePipeline (model={pipeline.model_kind}, "
                f"pose_bias={pipeline.pose_bias}, MAR>{MAR_OPEN}) "
                f"+ EyeTrax 0.4.0 features"),
    "screen": {"w": sw, "h": sh, "px_per_cm": px_per_cm,
               "viewing_distance_cm": VIEWING_DISTANCE_CM},
    "calibration": {
        "n_points": len(CALIB_MAP_PTS),
        "n_samples": len(pipeline._X_calib),  # type: ignore[attr-defined]
        "mouth_open_skips": mouth_skips,
    },
    "frames": {"total": total, "face_detected": face_ok,
               "detection_rate": det_rate,
               "avg_frame_ms": avg_ms, "fps": fps},
    "accuracy": {"mean_px": mean_acc, "mean_angular_deg": mean_ang,
                 "mean_precision_px": mean_prec},
    "per_target": eval_results,
}

with open("metrics_pipeline.json", "w") as f:
    json.dump(summary, f, indent=2)
with open("metrics_pipeline.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["wall_time", "phase", "target_x", "target_y",
                "gaze_x", "gaze_y", "blink", "frame_ms", "confidence"])
    w.writerows(csv_rows)

print("\n==== PIPELINE SUMMARY ====")
print(f"Model:     {pipeline.model_kind}  "
      f"(pose_bias={pipeline.pose_bias}, MAR>{MAR_OPEN})")
print(f"Frames:    {total}  ({face_ok} with face, {det_rate*100:.1f}% detection)")
print(f"FPS:       {fps:.1f}  (avg {avg_ms:.1f} ms/frame)")
print(f"Calib:     {len(pipeline._X_calib)} samples "  # type: ignore[attr-defined]
      f"across {len(CALIB_MAP_PTS)} targets  "
      f"(skipped {mouth_skips} mouth-open frames)")
print(f"Accuracy:  {mean_acc:.1f} px  (~{mean_ang:.2f}° at {VIEWING_DISTANCE_CM}cm)")
print(f"Precision: {mean_prec:.1f} px")
print("Saved: metrics_pipeline.json, metrics_pipeline.csv")
