"""
WebSocket server that streams gaze events from the EyeTrax pipeline to the
Flutter AAC app.

Protocol — server → client (every processed frame, ~30 fps):
    {"x": 0.45, "y": 0.62, "confidence": 0.92, "blink": false}

Protocol — client → server:
    {"type": "start_calibration"}        # trigger calibration pass

Protocol — server → client during calibration:
    {"type": "calibration_progress", "phase": "calibrating", "point": 3, "total": 13}
    {"type": "calibration_done"}
    {"type": "calibration_failed", "reason": "..."}

Threading model:
    pygame/SDL must own the main thread on macOS, so the camera + pygame
    loop runs on the main thread and the websockets server runs in a
    background asyncio loop. Communication is via thread-safe queues +
    asyncio.run_coroutine_threadsafe.
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import json
import queue
import threading
import math
import time
from typing import Optional

import cv2
import numpy as np
import pygame
import websockets

from gaze_pipeline import GazePipeline, CALIB_MAP_PTS, BIAS_PTS, MAR_OPEN


WINDOW_W, WINDOW_H = 1280, 800
CAM_W, CAM_H = 1280, 720
CALIB_DWELL_SEC = 1.8
CALIB_WARMUP_SEC = 0.4
BIAS_DWELL_SEC = 1.2
BIAS_WARMUP_SEC = 0.4

# --- Phase 0 positioning gate (pre-calibration face alignment) ---
POSITIONING_HOLD_SEC = 1.5          # continuous all-green needed to auto-advance
POSITIONING_MAX_SEC = 25.0          # fallback: proceed anyway so we never hang
POS_TZ_MIN, POS_TZ_MAX = 400, 850   # viewing-distance window (mm, |tz|)
POS_TX_MAX = 120                    # mm off-center horizontally
POS_TY_MAX = 180                    # mm off-center vertically
POS_YAW_MAX = 0.18                  # rad (~10°)
POS_PITCH_MAX = 0.22                # rad (~12.5°)


class GazeServer:
    """
    Owns:
      - the camera capture
      - the GazePipeline
      - the pygame window (created lazily on first calibration)
      - the set of connected WebSocket clients

    Main thread: runs `main_loop()`, which drives camera frames + pygame.
    Background thread: runs the asyncio event loop hosting the websocket
                       server.
    """

    def __init__(self, port: int = 8765, log_path: Optional[str] = None):
        self.port = port
        self.log_path = log_path
        self.pipeline = GazePipeline(window_size=(WINDOW_W, WINDOW_H))
        self.cap: Optional[cv2.VideoCapture] = None
        self.clients: set = set()

        # Cross-thread state. Lock guards `_calibration_requested` /
        # `_streaming` so the main thread can read/write them safely.
        self._lock = threading.Lock()
        self._calibration_requested = False
        self._streaming = True
        self._stop = False

        # Async loop handle so the main thread can schedule sends onto it.
        self._aio_loop: Optional[asyncio.AbstractEventLoop] = None

        # Pygame state (lazy)
        self._screen = None
        self._font_big = None
        self._font_small = None
        self._clock = None
        self._calibrating = False

        self._csv_writer = None
        self._csv_file = None

    # ------------------------------------------------------------------ #
    # Camera / log lifecycle
    # ------------------------------------------------------------------ #
    def open_camera(self):
        if self.cap is not None and self.cap.isOpened():
            return
        print("[ws_server] Opening camera (index 0)…")
        # On macOS prefer the AVFoundation backend; fall back to default.
        self.cap = cv2.VideoCapture(0, cv2.CAP_AVFOUNDATION)
        if not self.cap.isOpened():
            print("[ws_server]   AVFoundation backend failed, "
                  "trying default backend…")
            self.cap = cv2.VideoCapture(0)
        if not self.cap.isOpened():
            print("[ws_server]   ERROR: cannot open camera. "
                  "Check macOS Camera permission for your terminal "
                  "(System Settings → Privacy & Security → Camera).")
            self.cap = None
            return
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, CAM_W)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, CAM_H)
        # Read one frame to actually trigger the permission prompt.
        ret, _ = self.cap.read()
        w = self.cap.get(cv2.CAP_PROP_FRAME_WIDTH)
        h = self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT)
        print(f"[ws_server] Camera opened: {w:.0f}x{h:.0f}  "
              f"(test read: {'ok' if ret else 'FAILED'})")

    def close_camera(self):
        if self.cap is not None:
            self.cap.release()
            self.cap = None

    def open_log(self):
        if not self.log_path:
            return
        self._csv_file = open(self.log_path, "w", newline="")
        self._csv_writer = csv.writer(self._csv_file)
        self._csv_writer.writerow(
            ["wall_time", "x_norm", "y_norm", "confidence", "blink"]
        )

    def close_log(self):
        if self._csv_file is not None:
            self._csv_file.close()
            self._csv_file = None
            self._csv_writer = None

    # ------------------------------------------------------------------ #
    # Pygame lifecycle (main thread only)
    # ------------------------------------------------------------------ #
    def _ensure_pygame(self):
        if self._screen is not None:
            return
        pygame.init()
        pygame.font.init()
        self._screen = pygame.display.set_mode((WINDOW_W, WINDOW_H))
        pygame.display.set_caption("AAC Gaze — Calibration")
        self._font_big = pygame.font.SysFont("Arial", 40, bold=True)
        self._font_small = pygame.font.SysFont("Arial", 22)
        self._clock = pygame.time.Clock()

    def _draw_target(self, color, tgt_px, label):
        self._screen.fill((0, 0, 0))
        pygame.draw.circle(self._screen, color, tgt_px, 22)
        pygame.draw.circle(self._screen, (255, 255, 255), tgt_px, 6)
        txt = self._font_big.render(label, True, (255, 255, 255))
        self._screen.blit(txt, (40, 40))
        pygame.display.flip()

    # ------------------------------------------------------------------ #
    # Phase 0 — face positioning (runs on the main thread)
    # ------------------------------------------------------------------ #
    def _positioning_phase(self):
        """Pre-calibration face alignment. Shows a mirrored webcam preview
        with a readiness checklist (face / centered / distance / head level).
        Auto-advances after POSITIONING_HOLD_SEC of continuous all-green,
        SPACE skips, and a POSITIONING_MAX_SEC fallback proceeds anyway so the
        server never hangs if the user wanders off."""
        print("[ws_server] Phase 0: positioning")
        self._broadcast_threadsafe({
            "type": "calibration_progress", "phase": "positioning",
            "point": 0, "total": len(CALIB_MAP_PTS),
        })

        preview_w = min(int(WINDOW_W * 0.45), 720)
        preview_h = int(preview_w * CAM_H / CAM_W)
        preview_x = (WINDOW_W - preview_w) // 2
        preview_y = int(WINDOW_H * 0.08)
        list_x = preview_x
        list_y = preview_y + preview_h + int(WINDOW_H * 0.04)
        line_h = 32

        def _txt(s, pos, color=(255, 255, 255), big=False):
            f = self._font_big if big else self._font_small
            self._screen.blit(f.render(s, True, color), pos)

        t_ok_start = None
        t_phase_start = time.perf_counter()
        while True:
            for e in pygame.event.get():
                if e.type == pygame.KEYDOWN and e.key == pygame.K_SPACE:
                    return
            if time.perf_counter() - t_phase_start >= POSITIONING_MAX_SEC:
                return

            ret, frame = self.cap.read()
            if not ret:
                continue
            feats, _blink, pose, _mar = self.pipeline.extract(frame)

            face_ok = feats is not None
            if pose is not None:
                yaw, pitch, _roll, tx, ty, tz = pose.tolist()
                dist_cm = abs(tz) / 10.0
                centered = abs(tx) <= POS_TX_MAX and abs(ty) <= POS_TY_MAX
                dist_ok = POS_TZ_MIN <= abs(tz) <= POS_TZ_MAX
                orient_ok = abs(yaw) <= POS_YAW_MAX and abs(pitch) <= POS_PITCH_MAX
            else:
                yaw = pitch = tx = ty = tz = 0.0
                dist_cm = 0.0
                centered = dist_ok = orient_ok = False

            all_ok = face_ok and centered and dist_ok and orient_ok
            now = time.perf_counter()
            if all_ok:
                if t_ok_start is None:
                    t_ok_start = now
                elif now - t_ok_start >= POSITIONING_HOLD_SEC:
                    return
            else:
                t_ok_start = None

            # --- draw ---
            self._screen.fill((0, 0, 0))
            frame_rgb = cv2.cvtColor(cv2.flip(frame, 1), cv2.COLOR_BGR2RGB)
            preview = cv2.resize(frame_rgb, (preview_w, preview_h))
            preview_surf = pygame.surfarray.make_surface(
                np.ascontiguousarray(preview.swapaxes(0, 1)))
            border_color = (80, 220, 120) if all_ok else (255, 170, 40)
            pygame.draw.rect(self._screen, border_color,
                             (preview_x - 4, preview_y - 4,
                              preview_w + 8, preview_h + 8), 4)
            self._screen.blit(preview_surf, (preview_x, preview_y))

            oval = pygame.Rect(0, 0, int(preview_w * 0.45), int(preview_h * 0.7))
            oval.center = (preview_x + preview_w // 2,
                           preview_y + preview_h // 2)
            pygame.draw.ellipse(self._screen, (120, 180, 255), oval, 2)

            _txt("Position your face", (preview_x, preview_y - 60), big=True)

            checks = [
                ("Face detected", face_ok, ""),
                ("Centered", centered,
                 f"  (offset x={tx:+.0f}mm  y={ty:+.0f}mm)"
                 if pose is not None else "  (no face)"),
                ("Distance good", dist_ok,
                 f"  ({dist_cm:.0f} cm — aim 50-75 cm)"
                 if pose is not None else "  (no face)"),
                ("Head level", orient_ok,
                 f"  (yaw={math.degrees(yaw):+.0f}° pitch={math.degrees(pitch):+.0f}°)"
                 if pose is not None else "  (no face)"),
            ]
            for i, (label, ok, extra) in enumerate(checks):
                color = (120, 255, 120) if ok else (255, 130, 130)
                mark = "[OK]" if ok else "[  ]"
                _txt(f"{mark}  {label}{extra}", (list_x, list_y + i * line_h),
                     color)

            bottom_y = list_y + len(checks) * line_h + int(WINDOW_H * 0.03)
            if all_ok and t_ok_start is not None:
                remaining = POSITIONING_HOLD_SEC - (now - t_ok_start)
                _txt(f"Hold still — starting in {max(0.0, remaining):.1f}s",
                     (list_x, bottom_y), (120, 255, 120), big=True)
            else:
                _txt("Adjust your position. SPACE to start now.",
                     (list_x, bottom_y))

            pygame.display.flip()
            self._clock.tick(30)

    # ------------------------------------------------------------------ #
    # Calibration (runs on the main thread)
    # ------------------------------------------------------------------ #
    def _run_calibration(self):
        """Blocking calibration. Forwards progress events to all clients."""
        print("[ws_server] Calibration started")
        self.open_camera()
        self._ensure_pygame()
        # Bring the pygame window to the foreground so the user sees it.
        try:
            pygame.display.set_mode((WINDOW_W, WINDOW_H))
        except Exception:
            pass

        # Reset the existing pipeline for a fresh calibration run. We
        # deliberately do NOT construct a new GazePipeline here: on Windows a
        # second MediaPipe FaceLandmarker load mangles the absolute model path
        # (errno 22). reset_calibration() reuses the already-loaded landmarker.
        self.pipeline.reset_calibration()

        # Phase 0 — let the user align their face before the dots start.
        self._positioning_phase()

        total_calib = len(CALIB_MAP_PTS)

        # ---- Phase 1: calibration ----
        for i, (fx, fy) in enumerate(CALIB_MAP_PTS):
            tgt_px = (int(fx * WINDOW_W), int(fy * WINDOW_H))
            self._broadcast_threadsafe({
                "type": "calibration_progress",
                "phase": "calibrating", "point": i + 1, "total": total_calib,
            })
            t_start = time.perf_counter()
            while time.perf_counter() - t_start < CALIB_DWELL_SEC:
                for _ in pygame.event.get():
                    pass
                ret, frame = self.cap.read()
                if not ret:
                    continue
                feats, blink, pose, mar = self.pipeline.extract(frame)
                mouth_open = mar is not None and mar > MAR_OPEN
                remain = CALIB_DWELL_SEC - (time.perf_counter() - t_start)
                self._draw_target(
                    (100, 150, 255), tgt_px,
                    f"Calibration {i+1}/{total_calib}   {remain:.1f}s",
                )
                if (feats is not None and not blink and not mouth_open and
                        time.perf_counter() - t_start >= CALIB_WARMUP_SEC):
                    self.pipeline.add_calibration_sample(feats, tgt_px, pose)
                self._clock.tick(60)

        if not self.pipeline.train():
            self._broadcast_threadsafe({
                "type": "calibration_failed",
                "reason": "not enough calibration samples",
            })
            print("[ws_server] Calibration failed: not enough samples")
            return

        # ---- Phase 1b: bias ----
        for j, (fx, fy) in enumerate(BIAS_PTS):
            tgt_px = (int(fx * WINDOW_W), int(fy * WINDOW_H))
            self._broadcast_threadsafe({
                "type": "calibration_progress",
                "phase": "bias", "point": j + 1, "total": len(BIAS_PTS),
            })
            t_start = time.perf_counter()
            while time.perf_counter() - t_start < BIAS_DWELL_SEC:
                for _ in pygame.event.get():
                    pass
                ret, frame = self.cap.read()
                if not ret:
                    continue
                feats, blink, pose, mar = self.pipeline.extract(frame)
                mouth_open = mar is not None and mar > MAR_OPEN
                remain = BIAS_DWELL_SEC - (time.perf_counter() - t_start)
                self._draw_target(
                    (80, 220, 120), tgt_px,
                    f"Bias {j+1}/{len(BIAS_PTS)}   {remain:.1f}s",
                )
                if (feats is not None and not blink and not mouth_open and
                        time.perf_counter() - t_start >= BIAS_WARMUP_SEC):
                    self.pipeline.add_bias_sample(feats, tgt_px, pose)
                self._clock.tick(60)

        self.pipeline.fit_bias()
        self.pipeline.reset_smoothing()

        # Clear screen so it doesn't sit on the last target.
        self._screen.fill((0, 0, 0))
        msg = self._font_big.render("Calibration complete — you can switch back to the app.", True, (200, 255, 200))
        self._screen.blit(msg, (40, WINDOW_H // 2))
        pygame.display.flip()

        self._broadcast_threadsafe({"type": "calibration_done"})
        with self._lock:
            self._streaming = True
        print("[ws_server] Calibration complete")

    # ------------------------------------------------------------------ #
    # Streaming (runs on the main thread, between calibrations)
    # ------------------------------------------------------------------ #
    def _stream_frame(self):
        if self.cap is None:
            return
        ret, frame = self.cap.read()
        if not ret:
            return
        out = self.pipeline.process_frame(frame)
        if out is None:
            return
        self._broadcast_threadsafe(out)
        if self._csv_writer is not None:
            self._csv_writer.writerow([
                time.time(), out["x"], out["y"],
                out["confidence"], int(out["blink"]),
            ])

    # ------------------------------------------------------------------ #
    # Main loop — runs on the main thread
    # ------------------------------------------------------------------ #
    def main_loop(self):
        target_period = 1.0 / 30.0
        try:
            while not self._stop:
                t0 = time.perf_counter()

                # Check if calibration was requested.
                with self._lock:
                    do_calib = self._calibration_requested
                    self._calibration_requested = False
                    streaming = self._streaming

                if do_calib:
                    self._calibrating = True
                    with self._lock:
                        self._streaming = False
                    try:
                        self._run_calibration()
                    except Exception as e:
                        print(f"[ws_server] Calibration error: {e}")
                        self._broadcast_threadsafe({
                            "type": "calibration_failed",
                            "reason": str(e),
                        })
                    finally:
                        self._calibrating = False
                    continue

                # Stream frames (only when clients are connected + trained).
                if (streaming and self.pipeline.is_trained and self.clients):
                    self.open_camera()
                    self._stream_frame()

                # Even when idle, pump pygame events so the window (if open)
                # stays responsive.
                if self._screen is not None:
                    for _ in pygame.event.get():
                        pass

                elapsed = time.perf_counter() - t0
                time.sleep(max(0.0, target_period - elapsed))
        finally:
            self.close_camera()
            self.close_log()
            if self._screen is not None:
                pygame.quit()
            self.pipeline.close()

    # ------------------------------------------------------------------ #
    # Cross-thread broadcast
    # ------------------------------------------------------------------ #
    def _broadcast_threadsafe(self, payload: dict):
        """Called from the main thread; schedules a send on the async loop."""
        if self._aio_loop is None or not self.clients:
            return
        msg = json.dumps(payload)
        asyncio.run_coroutine_threadsafe(self._broadcast(msg), self._aio_loop)

    async def _broadcast(self, msg: str):
        if not self.clients:
            return
        dead = []
        for ws in list(self.clients):
            try:
                await ws.send(msg)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.clients.discard(ws)

    # ------------------------------------------------------------------ #
    # WebSocket handlers (run on the async background thread)
    # ------------------------------------------------------------------ #
    async def handle(self, ws):
        self.clients.add(ws)
        print(f"[ws_server] Client connected ({len(self.clients)} total)")
        try:
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                mtype = msg.get("type")
                print(f"[ws_server] Received: {mtype}")
                if mtype == "start_calibration":
                    with self._lock:
                        self._calibration_requested = True
                elif mtype == "start_stream":
                    if self.pipeline.is_trained:
                        with self._lock:
                            self._streaming = True
                    else:
                        await ws.send(json.dumps({
                            "type": "error",
                            "reason": "not calibrated",
                        }))
                elif mtype == "stop_stream":
                    with self._lock:
                        self._streaming = False
        except websockets.ConnectionClosed:
            pass
        finally:
            self.clients.discard(ws)
            print(f"[ws_server] Client disconnected "
                  f"({len(self.clients)} remaining)")

    async def _serve(self):
        self._aio_loop = asyncio.get_running_loop()
        print(f"[ws_server] Listening on ws://0.0.0.0:{self.port}")
        async with websockets.serve(self.handle, "0.0.0.0", self.port):
            # Park forever; the main thread does the real work.
            await asyncio.Future()

    def start_async_thread(self):
        def _runner():
            asyncio.run(self._serve())
        t = threading.Thread(target=_runner, daemon=True, name="ws-server")
        t.start()
        return t


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--log", type=str, default=None,
                   help="optional CSV path to log gaze events")
    args = p.parse_args()
    server = GazeServer(port=args.port, log_path=args.log)
    server.open_log()
    # Open the camera eagerly so the macOS permission prompt fires before
    # the user does anything else, and any failure is visible at boot.
    server.open_camera()
    server.start_async_thread()
    # Give the asyncio loop a tick to bind.
    time.sleep(0.2)
    try:
        server.main_loop()
    except KeyboardInterrupt:
        print("\n[ws_server] Shutting down.")
        server._stop = True


if __name__ == "__main__":
    main()
