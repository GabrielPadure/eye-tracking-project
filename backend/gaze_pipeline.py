"""
Reusable gaze pipeline — refactored from gaze_test_eyetrax.py and upgraded
with the improved-calibration changes.

Wraps EyeTrax feature extraction + a scikit-learn regressor (Ridge
by default) + 13-point calibration + 5-anchor *pose-aware* affine bias
correction + EMA smoothing + pose-gated confidence + mouth-open (MAR) gating
into a single class driven by either the standalone benchmark or the
WebSocket server.

EyeTrax is used only for the 489-dim feature vector + blink flag; the
features → (screen_x, screen_y) mapping is a separate sklearn model so we can
use a kernel/MLP regressor instead of EyeTrax's built-in linear Ridge.

Typical usage:

    pipe = GazePipeline(window_size=(1280, 800))
    # Calibration is normally driven by an external loop (pygame in the
    # benchmark; the WebSocket server in production) that calls
    # pipe.add_calibration_sample(...) and then pipe.train().
    pipe.train()
    # ... bias pass ...
    pipe.fit_bias()
    while True:
        out = pipe.process_frame(frame)
        if out is not None:
            send_to_client(out)   # {"x","y","confidence","blink"}
"""

from __future__ import annotations

import numpy as np

from sklearn.kernel_ridge import KernelRidge
from sklearn.linear_model import Ridge
from sklearn.neural_network import MLPRegressor
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import Pipeline

from eyetrax import GazeEstimator
from head_pose import HeadPoseEstimator


# --- defaults (mirror the improved gaze_test_eyetrax.py) ---
SMOOTH_ALPHA = 0.3
POSE_GATE_Z = 3.0
POSE_STD_FLOOR = np.array([0.05, 0.05, 0.05, 5.0, 5.0, 10.0], dtype=np.float32)

# Mouth-open threshold (lips separated by >MAR_OPEN * inter-eye distance).
# Closed mouth is ~0.02-0.05; talking/open ~0.25+. 0.18 is a safe margin.
MAR_OPEN = 0.18

# Default features → screen regressor. "ridge" matches the EyeTrax baseline;
# "kridge" (RBF KernelRidge) and "mlp" are also available.
DEFAULT_MODEL = "ridge"

CALIB_MAP_PTS = [
    (0.1, 0.1), (0.5, 0.1), (0.9, 0.1),
    (0.1, 0.5), (0.5, 0.5), (0.9, 0.5),
    (0.1, 0.9), (0.5, 0.9), (0.9, 0.9),
    (0.3, 0.3), (0.7, 0.3),
    (0.3, 0.7), (0.7, 0.7),
]
BIAS_PTS = [(0.2, 0.2), (0.8, 0.2), (0.5, 0.5), (0.2, 0.8), (0.8, 0.8)]


def _build_regressor(kind: str):
    """Feature-scaled scikit-learn regressor. Scaling matters a lot for
    KernelRidge/MLP (Ridge is scale-invariant after regularization-tuning
    but we scale anyway for consistency)."""
    if kind == "ridge":
        core = Ridge(alpha=1.0)
    elif kind == "kridge":
        # RBF kernel ridge. gamma set per-fit from feature variance.
        # alpha = L2 regularization on the dual coefficients.
        core = KernelRidge(kernel="rbf", alpha=0.5, gamma=None)
    elif kind == "mlp":
        core = MLPRegressor(hidden_layer_sizes=(128, 64), activation="relu",
                            solver="adam", alpha=1e-4, max_iter=600,
                            early_stopping=True, random_state=0)
    else:
        raise ValueError(f"unknown model: {kind}")
    return Pipeline([("scale", StandardScaler()), ("reg", core)])


class GazeModel:
    """Per-axis sklearn regressor that replaces eyetrax's built-in Ridge.
    EyeTrax is still used for feature extraction; only the mapping from
    features → (screen_x, screen_y) is swapped."""

    def __init__(self, kind: str):
        self.kind = kind
        self.model_x = _build_regressor(kind)
        self.model_y = _build_regressor(kind)

    def fit(self, X: np.ndarray, y: np.ndarray):
        # For KernelRidge with gamma=None, sklearn uses 1.0 — we instead
        # auto-scale so behavior matches 'scale' mode on the scaled inputs.
        if self.kind == "kridge":
            n_feat = X.shape[1]
            # After StandardScaler the per-feature variance is ~1, so
            # 1/n_features is a reasonable RBF width.
            for m in (self.model_x, self.model_y):
                m.set_params(reg__gamma=1.0 / n_feat)
        self.model_x.fit(X, y[:, 0])
        self.model_y.fit(X, y[:, 1])

    def predict(self, X: np.ndarray) -> np.ndarray:
        px = self.model_x.predict(X)
        py = self.model_y.predict(X)
        return np.column_stack([px, py])


class GazePipeline:
    """End-to-end gaze pipeline matching the improved benchmark configuration."""

    def __init__(self, window_size=(1280, 800), model_kind: str = DEFAULT_MODEL,
                 pose_bias: bool = True):
        self.window_w, self.window_h = window_size
        self.model_kind = model_kind
        self.pose_bias = pose_bias

        # EyeTrax is used for FEATURE EXTRACTION + blink only — never trained.
        self.est = GazeEstimator(model_name="ridge")
        self.pose_est = HeadPoseEstimator()

        # features → screen mapping (swappable sklearn regressor)
        self.gaze_model = GazeModel(model_kind)

        self._reset_state()

    def _reset_state(self):
        # Calibration accumulators
        self._X_calib: list = []
        self._y_calib: list = []
        self._pose_calib: list = []
        # Bias accumulator — each entry (raw_x, raw_y, tgt_x, tgt_y, pose|None)
        self._bias_raw: list = []
        # State
        self._trained = False
        # (coef_x, coef_y, use_pose, pose_mu, pose_sd)
        self._bias_model = None
        self._smooth_state = [None, None]
        self._pose_mu = None
        self._pose_sd = None

    # ------------------------------------------------------------------ #
    # Frame feature extraction
    # ------------------------------------------------------------------ #
    def extract(self, frame):
        """Return (feats, blink, pose, mar) for a single frame.

        feats/pose/mar may be None on failure. `mar` is the mouth-aspect
        ratio used to gate out talking/open-mouth frames."""
        if frame is None:
            return None, False, None, None
        try:
            feats, blink = self.est.extract_features(frame)
        except Exception:
            feats, blink = None, False
        pose, mar = self.pose_est.estimate_with_mar(frame)
        return feats, bool(blink), pose, mar

    # ------------------------------------------------------------------ #
    # Calibration
    # ------------------------------------------------------------------ #
    def reset_calibration(self):
        """Clear all accumulated calibration/bias/runtime state so this
        pipeline can be recalibrated from scratch.

        Crucially this reuses the existing MediaPipe FaceLandmarker (held by
        ``self.est``) rather than constructing a new GazeEstimator. On Windows,
        creating a second FaceLandmarker with an absolute ``model_asset_path``
        mangles the path (MediaPipe joins it onto its own resource root,
        producing ``…/site-packages/C:\\…\\face_landmarker.task`` → errno 22).
        The features→screen regressor is sklearn-only, so it is rebuilt fresh.
        """
        self.gaze_model = GazeModel(self.model_kind)
        self._reset_state()

    def add_calibration_sample(self, feats, target_px, pose=None):
        """Add a single calibration sample (called once per accepted frame)."""
        self._X_calib.append(feats)
        self._y_calib.append([target_px[0], target_px[1]])
        if pose is not None:
            self._pose_calib.append(pose)

    def train(self):
        """Train the regressor on accumulated calibration samples and fit the
        pose-gate statistics. Returns True on success."""
        if len(self._X_calib) < 20:
            return False
        X = np.vstack(self._X_calib)
        y = np.array(self._y_calib)
        self.gaze_model.fit(X, y)
        self._trained = True

        if len(self._pose_calib) >= 20:
            arr = np.vstack(self._pose_calib)
            self._pose_mu = arr.mean(axis=0)
            self._pose_sd = np.maximum(arr.std(axis=0), POSE_STD_FLOOR)
        return True

    # ------------------------------------------------------------------ #
    # Bias measurement
    # ------------------------------------------------------------------ #
    def add_bias_sample(self, feats, target_px, pose=None):
        """Predict raw gaze for `feats` and store (pred, target, pose) for the
        affine / pose-aware bias fit."""
        if not self._trained:
            return
        pred = self.gaze_model.predict(feats.reshape(1, -1))[0]
        self._bias_raw.append((float(pred[0]), float(pred[1]),
                               float(target_px[0]), float(target_px[1]),
                               pose if pose is not None else None))

    def fit_bias(self):
        """Fit a per-axis linear bias model from accumulated bias samples.

        Features depend on `pose_bias`:
            simple :  [1, raw_x, raw_y]
            + pose :  [1, raw_x, raw_y, yaw, pitch, roll, tx, ty, tz]  (pose z-scored)

        The pose-augmented version captures how the residual error depends on
        current head pose — learned *after* gaze regression, so it doesn't
        suffer the feature-scale mismatch that killed in-regressor pose use.
        """
        if len(self._bias_raw) < 10:
            return False

        have_pose = [b[4] is not None for b in self._bias_raw]
        use_pose = self.pose_bias and sum(have_pose) >= 10

        # Drop samples without pose so the design matrix is consistent.
        rows = [b for b in self._bias_raw if (b[4] is not None or not use_pose)]
        arr = np.array([[b[0], b[1], b[2], b[3]] for b in rows])
        px_v, py_v = arr[:, 0], arr[:, 1]
        tx_v, ty_v = arr[:, 2], arr[:, 3]

        if use_pose:
            P = np.array([b[4] for b in rows], dtype=np.float64)
            pose_bias_mu = P.mean(axis=0)
            pose_bias_sd = np.maximum(P.std(axis=0),
                                      POSE_STD_FLOOR.astype(np.float64))
            P_z = (P - pose_bias_mu) / pose_bias_sd
            A = np.column_stack([np.ones(len(arr)), px_v, py_v, P_z])
        else:
            pose_bias_mu = None
            pose_bias_sd = None
            A = np.column_stack([np.ones(len(arr)), px_v, py_v])

        coef_x, *_ = np.linalg.lstsq(A, tx_v, rcond=None)
        coef_y, *_ = np.linalg.lstsq(A, ty_v, rcond=None)
        self._bias_model = (coef_x, coef_y, use_pose, pose_bias_mu, pose_bias_sd)
        return True

    # ------------------------------------------------------------------ #
    # Live prediction
    # ------------------------------------------------------------------ #
    def _apply_correction(self, raw_x, raw_y, pose=None):
        """Bias-corrected gaze. Uses pose if the model was fit with it and
        current pose is available; falls back to the calibration-mean pose
        (z=0) if pose is missing at runtime."""
        if self._bias_model is None:
            return raw_x, raw_y
        cx, cy, use_pose, pmu, psd = self._bias_model
        if use_pose:
            if pose is not None:
                p_z = (np.asarray(pose, dtype=np.float64) - pmu) / psd
            else:
                p_z = np.zeros(6, dtype=np.float64)
            v = np.concatenate([[1.0, raw_x, raw_y], p_z])
        else:
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

    def _normalised(self, sx, sy, conf, blink):
        return {
            "x": max(0.0, min(1.0, sx / self.window_w)),
            "y": max(0.0, min(1.0, sy / self.window_h)),
            "confidence": conf,
            "blink": bool(blink),
        }

    def process_frame(self, frame):
        """Run the full pipeline on a raw BGR frame.

        Returns a dict {"x","y","confidence","blink"} with x/y normalised to
        [0,1] over the configured window size. Returns None when no face is
        detected.

        On a blink OR an open mouth (talking), the last smoothed position is
        held (smoothing is not advanced) and `blink` is reported True so the
        client cancels any in-progress dwell — preventing false selections.
        """
        if not self._trained:
            return None
        feats, blink, pose, mar = self.extract(frame)
        if feats is None:
            return None

        conf = self._pose_confidence(pose)
        mouth_open = mar is not None and mar > MAR_OPEN

        if blink or mouth_open:
            if self._smooth_state[0] is None:
                return None
            sx, sy = self._smooth_state
            return self._normalised(sx, sy, conf, True)

        raw = self.gaze_model.predict(feats.reshape(1, -1))[0]
        corr_x, corr_y = self._apply_correction(float(raw[0]), float(raw[1]), pose)
        sx, sy = self._smooth(corr_x, corr_y)
        return self._normalised(sx, sy, conf, False)

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
