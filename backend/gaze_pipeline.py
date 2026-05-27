"""
Reusable gaze pipeline — refactored from gaze_test_eyetrax.py.

Wraps the EyeTrax Ridge regressor + 13-point calibration + 5-anchor affine
bias correction + EMA smoothing + pose-gated confidence into a single class
that can be driven by either the standalone benchmark or the WebSocket
server.

Typical usage:

    pipe = GazePipeline(window_size=(1280, 800))
    # Calibration is normally driven by an external loop (pygame in the
    # benchmark; the WebSocket server in production) that calls
    # pipe.add_calibration_sample(...) and then pipe.finish_calibration().
    pipe.train()
    pipe.measure_bias(...)
    while True:
        out = pipe.process_frame(frame)
        if out is not None:
            send_to_client(out)   # {"x","y","confidence","blink"}
"""

from __future__ import annotations

import time
import numpy as np
import cv2

from eyetrax import GazeEstimator
from head_pose import HeadPoseEstimator


# --- defaults (mirror gaze_test_eyetrax.py exactly) ---
SMOOTH_ALPHA = 0.3
POSE_GATE_Z = 3.0
POSE_STD_FLOOR = np.array([0.05, 0.05, 0.05, 5.0, 5.0, 10.0], dtype=np.float32)

CALIB_MAP_PTS = [
    (0.1, 0.1), (0.5, 0.1), (0.9, 0.1),
    (0.1, 0.5), (0.5, 0.5), (0.9, 0.5),
    (0.1, 0.9), (0.5, 0.9), (0.9, 0.9),
    (0.3, 0.3), (0.7, 0.3),
    (0.3, 0.7), (0.7, 0.7),
]
BIAS_PTS = [(0.2, 0.2), (0.8, 0.2), (0.5, 0.5), (0.2, 0.8), (0.8, 0.8)]


class GazePipeline:
    """End-to-end gaze pipeline matching the Phase 2 benchmark configuration."""

    def __init__(self, window_size=(1280, 800)):
        self.window_w, self.window_h = window_size
        self.est = GazeEstimator(model_name="ridge")
        self.pose_est = HeadPoseEstimator()

        # Calibration accumulators
        self._X_calib: list = []
        self._y_calib: list = []
        self._pose_calib: list = []

        # Bias accumulator
        self._bias_raw: list = []

        # State
        self._trained = False
        self._bias_model = None
        self._smooth_state = [None, None]
        self._pose_mu = None
        self._pose_sd = None

    # ------------------------------------------------------------------ #
    # Frame feature extraction
    # ------------------------------------------------------------------ #
    def extract(self, frame):
        """Return (feats, blink, pose) for a single frame. None on failure."""
        if frame is None:
            return None, False, None
        try:
            feats, blink = self.est.extract_features(frame)
        except Exception:
            feats, blink = None, False
        pose = self.pose_est.estimate(frame)
        return feats, bool(blink), pose

    # ------------------------------------------------------------------ #
    # Calibration
    # ------------------------------------------------------------------ #
    def add_calibration_sample(self, feats, target_px, pose=None):
        """Add a single calibration sample (called once per accepted frame)."""
        self._X_calib.append(feats)
        self._y_calib.append([target_px[0], target_px[1]])
        if pose is not None:
            self._pose_calib.append(pose)

    def train(self):
        """Train the Ridge regressor on accumulated calibration samples and
        fit the pose-gate statistics. Returns True on success."""
        if len(self._X_calib) < 20:
            return False
        X = np.vstack(self._X_calib)
        y = np.array(self._y_calib)
        self.est.train(X, y)
        self._trained = True

        if len(self._pose_calib) >= 20:
            arr = np.vstack(self._pose_calib)
            self._pose_mu = arr.mean(axis=0)
            self._pose_sd = np.maximum(arr.std(axis=0), POSE_STD_FLOOR)
        return True

    # ------------------------------------------------------------------ #
    # Bias measurement
    # ------------------------------------------------------------------ #
    def add_bias_sample(self, feats, target_px):
        """Predict raw gaze for `feats` and store (pred, target) for affine fit."""
        if not self._trained:
            return
        pred = self.est.predict(feats.reshape(1, -1))[0]
        self._bias_raw.append((float(pred[0]), float(pred[1]),
                               float(target_px[0]), float(target_px[1])))

    def fit_bias(self):
        """Fit per-axis affine bias model from accumulated bias samples."""
        if len(self._bias_raw) < 10:
            return False
        arr = np.array(self._bias_raw)
        A = np.column_stack([np.ones(len(arr)), arr[:, 0], arr[:, 1]])
        coef_x, *_ = np.linalg.lstsq(A, arr[:, 2], rcond=None)
        coef_y, *_ = np.linalg.lstsq(A, arr[:, 3], rcond=None)
        self._bias_model = (coef_x, coef_y)
        return True

    # ------------------------------------------------------------------ #
    # Live prediction
    # ------------------------------------------------------------------ #
    def _apply_correction(self, raw_x, raw_y):
        if self._bias_model is None:
            return raw_x, raw_y
        cx, cy = self._bias_model
        v = np.array([1.0, raw_x, raw_y])
        return float(cx @ v), float(cy @ v)

    def _smooth(self, x, y):
        if self._smooth_state[0] is None:
            self._smooth_state[0], self._smooth_state[1] = x, y
        else:
            self._smooth_state[0] = (
                SMOOTH_ALPHA * x + (1 - SMOOTH_ALPHA) * self._smooth_state[0]
            )
            self._smooth_state[1] = (
                SMOOTH_ALPHA * y + (1 - SMOOTH_ALPHA) * self._smooth_state[1]
            )
        return self._smooth_state[0], self._smooth_state[1]

    def _pose_confidence(self, pose):
        if self._pose_mu is None or pose is None:
            return 1.0
        z = np.sqrt(np.mean(((pose - self._pose_mu) / self._pose_sd) ** 2))
        return float(max(0.0, 1.0 - z / POSE_GATE_Z))

    def process_frame(self, frame):
        """Run the full pipeline on a raw BGR frame.

        Returns a dict {"x","y","confidence","blink"} with x/y normalised to
        [0,1] over the configured window size. Returns None when no face is
        detected (caller can choose to skip or hold the previous value).
        """
        if not self._trained:
            return None
        feats, blink, pose = self.extract(frame)
        if feats is None:
            return None

        raw = self.est.predict(feats.reshape(1, -1))[0]
        corr_x, corr_y = self._apply_correction(float(raw[0]), float(raw[1]))
        sx, sy = self._smooth(corr_x, corr_y)
        conf = self._pose_confidence(pose)
        return {
            "x": max(0.0, min(1.0, sx / self.window_w)),
            "y": max(0.0, min(1.0, sy / self.window_h)),
            "confidence": conf,
            "blink": bool(blink),
        }

    # ------------------------------------------------------------------ #
    # Lifecycle
    # ------------------------------------------------------------------ #
    @property
    def is_trained(self) -> bool:
        return self._trained

    def reset_smoothing(self):
        self._smooth_state = [None, None]

    def close(self):
        try:
            self.pose_est.close()
        except Exception:
            pass
