"""
EyeTrax gaze tracking benchmark — mirror of gaze_test.py for direct comparison.

EyeTrax API:
  est = GazeEstimator()
  feats, blink = est.extract_features(frame)     # frame: BGR ndarray; feats: 1D vector or None
  est.train(X, y)                                # X: (N, D), y: (N, 2) screen coords
  pred = est.predict(X)                          # pred: (N, 2)

Phases match gaze_test.py:
  1. Calibration — for each target, sit on it for CALIB_DWELL_SEC collecting features.
  2. Evaluation — same 9 targets, 2s each, log per-frame prediction.
  3. Free tracking — press Q to save.

Outputs: metrics_eyetrax.json, metrics_eyetrax.csv
"""

import os
import csv
import json
import time
import math
import cv2
import pygame
import numpy as np

from eyetrax import GazeEstimator
from head_pose import HeadPoseEstimator

# --- config ---
WINDOW_W, WINDOW_H = 1280, 800
CAM_W, CAM_H = 1280, 720
CALIB_DWELL_SEC = 1.8             # time per calibration target
CALIB_WARMUP_SEC = 0.4            # ignore first N seconds (eye saccading in)
CALIB_MAP_PTS = [
    (0.1, 0.1), (0.5, 0.1), (0.9, 0.1),
    (0.1, 0.5), (0.5, 0.5), (0.9, 0.5),
    (0.1, 0.9), (0.5, 0.9), (0.9, 0.9),
    (0.3, 0.3), (0.7, 0.3),
    (0.3, 0.7), (0.7, 0.7),
]
# Validation pass (brief) — used to measure per-region bias after training, then
# subtracted from live predictions. Reuses 5 corners+center.
BIAS_PTS = [(0.2, 0.2), (0.8, 0.2), (0.5, 0.5), (0.2, 0.8), (0.8, 0.8)]
BIAS_DWELL_SEC = 1.2
BIAS_WARMUP_SEC = 0.4
EVAL_POINTS = [(0.2, 0.2), (0.5, 0.2), (0.8, 0.2),
               (0.2, 0.5), (0.5, 0.5), (0.8, 0.5),
               (0.2, 0.8), (0.5, 0.8), (0.8, 0.8)]
EVAL_HOLD_SEC = 2.0
EVAL_WARMUP_SEC = 0.6
# Exponential smoothing on live predictions. α higher = more responsive.
SMOOTH_ALPHA = 0.3
VIEWING_DISTANCE_CM = 60.0
SCREEN_DIAG_INCHES = 15.6

# Pose-gated confidence: if current head pose differs from the calibration
# pose distribution by more than POSE_GATE_Z standardized units (RMS-z
# across all 6 pose dims), gaze predictions are flagged low-confidence.
POSE_GATE_Z = 3.0
# Minimum per-dim std used when building the gate — prevents a pathologically
# tight gate when the user happens to hold very still during calibration.
# Order: [yaw, pitch, roll, tx, ty, tz]. Rotations in radians, translations
# in millimetres. These correspond to ~3° of rotation and 5–10 mm of shift
# as the "natural breathing-room" floor, so the regressor is still trusted
# for realistic small head movements at eval time.
POSE_STD_FLOOR = np.array([0.05, 0.05, 0.05, 5.0, 5.0, 10.0], dtype=np.float32)

# --- init ---
pygame.init()
pygame.font.init()
sw, sh = WINDOW_W, WINDOW_H
screen = pygame.display.set_mode((sw, sh))
pygame.display.set_caption("Gaze Test — EyeTrax")
font_small = pygame.font.SysFont("Arial", 22)
font_big = pygame.font.SysFont("Arial", 40, bold=True)

diag_px = math.hypot(sw, sh)
px_per_cm = diag_px / (SCREEN_DIAG_INCHES * 2.54)

est = GazeEstimator(model_name="ridge")
pose_est = HeadPoseEstimator()

cap = cv2.VideoCapture(0)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, CAM_W)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, CAM_H)
print(f"Camera: {cap.get(cv2.CAP_PROP_FRAME_WIDTH)}x{cap.get(cv2.CAP_PROP_FRAME_HEIGHT)}")

clock = pygame.time.Clock()

# --- metrics ---
csv_rows = []
eval_results = []
frame_times = []
face_ok = 0
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


def grab_features():
    """Capture one frame; return (features, blink, pose, dt_ms). Pose is
    returned as a 6-dim vector or None on failure. It is NOT fed to the
    Ridge regressor (that regressed in all experiments) — only used to
    gate output confidence at runtime."""
    global total
    total += 1
    ret, frame = cap.read()
    t0 = time.perf_counter()
    if not ret:
        return None, False, None, 0.0
    try:
        feats, blink = est.extract_features(frame)
    except Exception:
        feats, blink = None, False
    pose = pose_est.estimate(frame)
    dt = (time.perf_counter() - t0) * 1000.0
    return feats, blink, pose, dt


# =========================================================
# PHASE 1: CALIBRATION
# =========================================================
print("Phase 1: calibration — stare at each blue dot until it moves.")
X_calib = []
y_calib = []
pose_calib = []   # pose samples collected during calibration, used for the gate
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
        feats, blink, pose, dt = grab_features()
        frame_times.append(dt)

        screen.fill((0, 0, 0))
        pygame.draw.circle(screen, (100, 150, 255), tgt_px, 18)
        pygame.draw.circle(screen, (255, 255, 255), tgt_px, 6)
        remain = CALIB_DWELL_SEC - (time.perf_counter() - t_start)
        txt(f"Calibration {i+1}/{len(CALIB_MAP_PTS)}   {remain:.1f}s",
            (40, 40), big=True)

        if feats is not None:
            face_ok += 1
            if (time.perf_counter() - t_start >= CALIB_WARMUP_SEC
                    and not blink):
                X_calib.append(feats)
                y_calib.append([tgt_px[0], tgt_px[1]])
                if pose is not None:
                    pose_calib.append(pose)
        else:
            txt("No face detected", (40, sh - 80), (255, 80, 80))

        pygame.display.flip()
        clock.tick(60)

if not running or len(X_calib) < 20:
    print(f"Not enough calibration samples ({len(X_calib)}), aborting.")
    pygame.quit()
    cap.release()
    raise SystemExit(1)

X_calib = np.vstack(X_calib)
y_calib = np.array(y_calib)
print(f"Collected {len(X_calib)} calibration samples. Training…")
est.train(X_calib, y_calib)
print("Training done.")

# Fit pose-gate stats: mean + per-dim std across calibration pose samples.
# At runtime, the z-score distance `sqrt(sum(((p - mu)/sd)**2)/6)` measures
# how far the current head is from the calibration pose distribution.
# Above POSE_GATE_Z we stop trusting the prediction.
if len(pose_calib) >= 20:
    pose_calib_arr = np.vstack(pose_calib)
    pose_mu = pose_calib_arr.mean(axis=0)
    raw_sd = pose_calib_arr.std(axis=0)
    # Floor each dim so a user who sat perfectly still doesn't produce a
    # gate so narrow that natural eval-time head movement gets rejected.
    pose_sd = np.maximum(raw_sd, POSE_STD_FLOOR)
    print(f"Pose gate — mu={np.round(pose_mu, 3).tolist()}  "
          f"sd_raw={np.round(raw_sd, 3).tolist()}  "
          f"sd_used={np.round(pose_sd, 3).tolist()}  (gate z={POSE_GATE_Z})")
else:
    pose_mu = None
    pose_sd = None
    print(f"Only {len(pose_calib)} pose samples — disabling pose gate.")


def pose_confidence(pose):
    """1.0 when pose is near calibration mean, dropping to 0.0 at POSE_GATE_Z.
    Returns (confidence, z_deviation)."""
    if pose_mu is None or pose is None:
        return 1.0, 0.0
    z = np.sqrt(np.mean(((pose - pose_mu) / pose_sd) ** 2))
    conf = max(0.0, 1.0 - z / POSE_GATE_Z)
    return float(conf), float(z)

# =========================================================
# PHASE 1b: BIAS MEASUREMENT
# =========================================================
# Run a short validation pass. For each anchor target, record mean (pred - target).
# Fit a simple affine bias model:  corrected = raw - (a + b*raw_x + c*raw_y)
# (Per-axis linear model — captures constant offset + screen-position drift.)
print("Phase 1b: bias measurement — stare at each green dot briefly.")
bias_raw = []      # list of (raw_pred_xy, target_xy)
for (fx, fy) in BIAS_PTS:
    if not running:
        break
    tgt_px = (int(fx * sw), int(fy * sh))
    t_start = time.perf_counter()
    while time.perf_counter() - t_start < BIAS_DWELL_SEC:
        if not handle_events():
            running = False
            break
        feats, blink, pose, dt = grab_features()
        frame_times.append(dt)
        screen.fill((0, 0, 0))
        pygame.draw.circle(screen, (80, 220, 120), tgt_px, 22)
        pygame.draw.circle(screen, (255, 255, 255), tgt_px, 6)
        remain = BIAS_DWELL_SEC - (time.perf_counter() - t_start)
        txt(f"Bias check {len(bias_raw)//40 + 1}/{len(BIAS_PTS)}  {remain:.1f}s",
            (40, 40), big=True)
        if feats is not None:
            face_ok += 1
            if (time.perf_counter() - t_start >= BIAS_WARMUP_SEC and not blink):
                pred = est.predict(feats.reshape(1, -1))[0]
                bias_raw.append((float(pred[0]), float(pred[1]),
                                 float(tgt_px[0]), float(tgt_px[1])))
        pygame.display.flip()
        clock.tick(60)

# Fit per-axis affine model  target = A @ [1, px, py]  (least squares).
# Then at runtime:  corrected = A @ [1, raw_x, raw_y]
bias_model = None
if len(bias_raw) >= 10:
    arr = np.array(bias_raw)  # columns: px, py, tx, ty
    A = np.column_stack([np.ones(len(arr)), arr[:, 0], arr[:, 1]])
    coef_x, *_ = np.linalg.lstsq(A, arr[:, 2], rcond=None)
    coef_y, *_ = np.linalg.lstsq(A, arr[:, 3], rcond=None)
    bias_model = (coef_x, coef_y)
    # Report the mean raw offset for sanity.
    mean_dx = float(np.mean(arr[:, 2] - arr[:, 0]))
    mean_dy = float(np.mean(arr[:, 3] - arr[:, 1]))
    print(f"Bias model fit on {len(arr)} samples. "
          f"Mean raw offset: dx={mean_dx:+.1f}px, dy={mean_dy:+.1f}px")
else:
    print(f"Only {len(bias_raw)} bias samples collected — skipping bias correction.")


def apply_correction(raw_x, raw_y):
    """Apply affine bias correction to a raw prediction."""
    if bias_model is None:
        return raw_x, raw_y
    cx, cy = bias_model
    v = np.array([1.0, raw_x, raw_y])
    return float(cx @ v), float(cy @ v)


# Smoothing state (exponential moving average)
smooth_state = [None, None]


def smooth(x, y):
    if smooth_state[0] is None:
        smooth_state[0], smooth_state[1] = x, y
    else:
        smooth_state[0] = SMOOTH_ALPHA * x + (1 - SMOOTH_ALPHA) * smooth_state[0]
        smooth_state[1] = SMOOTH_ALPHA * y + (1 - SMOOTH_ALPHA) * smooth_state[1]
    return smooth_state[0], smooth_state[1]


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
        feats, blink, pose, dt = grab_features()
        frame_times.append(dt)

        screen.fill((0, 0, 0))
        pygame.draw.circle(screen, (255, 60, 60), tgt_px, 30)
        pygame.draw.circle(screen, (255, 255, 255), tgt_px, 8)

        gx = gy = None
        if feats is not None:
            face_ok += 1
            raw = est.predict(feats.reshape(1, -1))[0]
            corr_x, corr_y = apply_correction(float(raw[0]), float(raw[1]))
            sx, sy = smooth(corr_x, corr_y)
            gx, gy = int(sx), int(sy)
            conf, zdev = pose_confidence(pose)
            # Green = trusted, orange ring = low-confidence (pose out of range).
            color = (0, 255, 0) if conf >= 0.5 else (255, 170, 40)
            pygame.draw.circle(screen, color, (gx, gy), 10, 2)
            csv_rows.append([time.time(), "eval", tgt_px[0], tgt_px[1],
                             gx, gy, int(blink), dt, conf, zdev])
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
    feats, blink, pose, dt = grab_features()
    frame_times.append(dt)

    screen.fill((0, 0, 0))
    if feats is not None:
        face_ok += 1
        raw = est.predict(feats.reshape(1, -1))[0]
        corr_x, corr_y = apply_correction(float(raw[0]), float(raw[1]))
        sx, sy = smooth(corr_x, corr_y)
        gx, gy = int(sx), int(sy)
        conf, zdev = pose_confidence(pose)
        csv_rows.append([time.time(), "free", -1, -1, gx, gy,
                         int(blink), dt, conf, zdev])
        color = (0, 255, 0) if conf >= 0.5 else (255, 170, 40)
        pygame.draw.circle(screen, color, (gx, gy), 14, 3)
        gate = "OK" if conf >= 0.5 else "LOW"
        txt(f"gaze=({gx},{gy})  blink={blink}  "
            f"conf={conf:.2f}  z={zdev:.2f}  [{gate}]", (40, 40))
    else:
        txt("No face detected", (40, 40), (255, 80, 80))
    txt("Press Q to finish", (40, sh - 40))
    pygame.display.flip()
    clock.tick(60)

cap.release()
pygame.quit()
pose_est.close()

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
    "library": "eyetrax-0.4.0 (ridge) + affine bias + EMA + pose-gated confidence",
    "screen": {"w": sw, "h": sh, "px_per_cm": px_per_cm,
               "viewing_distance_cm": VIEWING_DISTANCE_CM},
    "calibration": {"n_points": len(CALIB_MAP_PTS), "n_samples": len(X_calib)},
    "post_processing": {
        "bias_correction": bias_model is not None,
        "bias_samples": len(bias_raw),
        "smoothing_alpha": SMOOTH_ALPHA,
    },
    "pose_gate": {
        "enabled": pose_mu is not None,
        "calibration_samples": len(pose_calib),
        "z_threshold": POSE_GATE_Z,
        "mean": pose_mu.tolist() if pose_mu is not None else None,
        "std": pose_sd.tolist() if pose_sd is not None else None,
    },
    "frames": {"total": total, "face_detected": face_ok,
               "detection_rate": det_rate,
               "avg_frame_ms": avg_ms, "fps": fps},
    "accuracy": {"mean_px": mean_acc, "mean_angular_deg": mean_ang,
                 "mean_precision_px": mean_prec},
    "per_target": eval_results,
}

with open("metrics_eyetrax.json", "w") as f:
    json.dump(summary, f, indent=2)
with open("metrics_eyetrax.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["wall_time", "phase", "target_x", "target_y",
                "gaze_x", "gaze_y", "blink", "frame_ms",
                "pose_confidence", "pose_z_deviation"])
    w.writerows(csv_rows)

print("\n==== EYETRAX SUMMARY ====")
print(f"Frames:    {total}  ({face_ok} with face, {det_rate*100:.1f}% detection)")
print(f"FPS:       {fps:.1f}  (avg {avg_ms:.1f} ms/frame)")
print(f"Calib:     {len(X_calib)} samples across {len(CALIB_MAP_PTS)} targets")
print(f"Accuracy:  {mean_acc:.1f} px  (~{mean_ang:.2f}° at {VIEWING_DISTANCE_CM}cm)")
print(f"Precision: {mean_prec:.1f} px")
print("Saved: metrics_eyetrax.json, metrics_eyetrax.csv")
