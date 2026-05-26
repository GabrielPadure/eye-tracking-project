"""
Head-pose estimation via MediaPipe Face Mesh + solvePnP.

Returns a 6-dim vector per frame: [yaw, pitch, roll, tx, ty, tz] where
rotations are radians and translations are in the camera's own units
(roughly millimetres because the 3D canonical model is in mm).

This is used two ways in the benchmarks:
  (a) EyeTrax: appended to the 489-dim feature vector so the Ridge
      regressor can compensate for head movement during training.
  (b) EyeGestures: used post-hoc as conditioning for a pose-aware bias
      model (learned from calibration residuals), since its internal
      feature pipeline is not exposed.

The 3D canonical face model is Ahmed Mohamed's 6-point approximation,
widely used for solvePnP head pose. MediaPipe indices chosen to match:
  1   — nose tip
  152 — chin
  33  — left eye outer corner
  263 — right eye outer corner
  61  — left mouth corner
  291 — right mouth corner
"""

from __future__ import annotations

import numpy as np
import cv2

# Canonical 3D face model (millimetres). X right, Y down, Z into camera.
CANONICAL_3D = np.array([
    [0.0,    0.0,    0.0],     # 1    nose tip
    [0.0,   63.6,  -12.5],     # 152  chin
    [-43.3, -32.7, -26.0],     # 33   left eye outer corner
    [43.3,  -32.7, -26.0],     # 263  right eye outer corner
    [-28.9, 28.9,  -24.1],     # 61   left mouth corner
    [28.9,  28.9,  -24.1],     # 291  right mouth corner
], dtype=np.float64)

MP_INDICES = [1, 152, 33, 263, 61, 291]


def _camera_matrix(frame_w: int, frame_h: int) -> np.ndarray:
    # Pinhole assumption: focal ≈ image width, principal point at centre.
    # Good enough for laptop webcams where we lack a calibration rig.
    f = float(frame_w)
    cx, cy = frame_w / 2.0, frame_h / 2.0
    return np.array([[f, 0, cx], [0, f, cy], [0, 0, 1]], dtype=np.float64)


def _rvec_to_euler(rvec: np.ndarray) -> tuple[float, float, float]:
    """Rotation vector → (yaw, pitch, roll) radians."""
    R, _ = cv2.Rodrigues(rvec)
    sy = np.sqrt(R[0, 0] ** 2 + R[1, 0] ** 2)
    singular = sy < 1e-6
    if not singular:
        pitch = np.arctan2(R[2, 1], R[2, 2])
        yaw = np.arctan2(-R[2, 0], sy)
        roll = np.arctan2(R[1, 0], R[0, 0])
    else:
        pitch = np.arctan2(-R[1, 2], R[1, 1])
        yaw = np.arctan2(-R[2, 0], sy)
        roll = 0.0
    return float(yaw), float(pitch), float(roll)


class HeadPoseEstimator:
    """
    Lightweight wrapper around MediaPipe Face Mesh that returns a 6-dim
    head-pose vector per frame. Keeps its own mesh instance — independent
    of whatever EyeTrax/EyeGestures are doing internally — so both
    benchmarks use identical pose numbers.
    """

    def __init__(self):
        import mediapipe as mp  # type: ignore
        self._mp = mp
        self._mesh = mp.solutions.face_mesh.FaceMesh(
            static_image_mode=False,
            max_num_faces=1,
            refine_landmarks=False,
            min_detection_confidence=0.5,
            min_tracking_confidence=0.5,
        )
        self._cam_mtx: np.ndarray | None = None
        self._dist = np.zeros((4, 1), dtype=np.float64)

    def estimate(self, frame_bgr) -> np.ndarray | None:
        """Return [yaw, pitch, roll, tx, ty, tz] or None on failure."""
        if frame_bgr is None:
            return None
        h, w = frame_bgr.shape[:2]
        if self._cam_mtx is None:
            self._cam_mtx = _camera_matrix(w, h)

        rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
        # MediaPipe Face Mesh expects writable=False for speed.
        rgb.flags.writeable = False
        res = self._mesh.process(rgb)
        if not res.multi_face_landmarks:
            return None
        lms = res.multi_face_landmarks[0].landmark

        pts_2d = np.array(
            [[lms[i].x * w, lms[i].y * h] for i in MP_INDICES],
            dtype=np.float64,
        )
        ok, rvec, tvec = cv2.solvePnP(
            CANONICAL_3D, pts_2d, self._cam_mtx, self._dist,
            flags=cv2.SOLVEPNP_ITERATIVE,
        )
        if not ok:
            return None
        yaw, pitch, roll = _rvec_to_euler(rvec)
        tx, ty, tz = float(tvec[0, 0]), float(tvec[1, 0]), float(tvec[2, 0])
        return np.array([yaw, pitch, roll, tx, ty, tz], dtype=np.float32)

    def close(self):
        try:
            self._mesh.close()
        except Exception:
            pass

    def __del__(self):
        self.close()
