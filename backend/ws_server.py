"""
WebSocket server that streams gaze events from the EyeTrax pipeline to the
Flutter AAC app.

Protocol — server → client (every processed frame, ~30 fps):
    {"x": 0.45, "y": 0.62, "confidence": 0.92, "blink": false}

Protocol — client → server:
    {"type": "start_calibration"}        # trigger calibration pass
    {"type": "start_stream"}             # resume gaze streaming
    {"type": "stop_stream"}              # pause gaze streaming
    {"type": "shutdown"}                 # kill the server (Quit button)

Protocol — server → client during calibration:
    {"type": "calibration_progress", "phase": "calibrating", "point": 3, "total": 13, "x": 0.5, "y": 0.1}
    {"type": "calibration_done"}
    {"type": "calibration_failed", "reason": "..."}

Threading model:
    Main thread runs camera capture and calibration/streaming. The websocket
    server runs on a background asyncio loop. Communication is via
    asyncio.run_coroutine_threadsafe.
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import json
import mimetypes
import sys
import threading
import time
from pathlib import Path
from typing import Optional

import cv2
import websockets
from websockets.datastructures import Headers
from websockets.http11 import Response

from gaze_pipeline import GazePipeline, CALIB_MAP_PTS, BIAS_PTS, MAR_OPEN


# --------------------------------------------------------------------------- #
# Resource paths — work both in dev (running from source) and packed (PyInstaller).
# --------------------------------------------------------------------------- #
def resource_path(*parts: str) -> Path:
    """Resolve a path relative to the bundled resources directory.

    Under PyInstaller the bundle is extracted to ``sys._MEIPASS``; in dev we
    fall back to the project root (one level above ``backend/``).
    """
    base = getattr(sys, "_MEIPASS", None)
    if base is None:
        # backend/ws_server.py → project root
        base = Path(__file__).resolve().parent.parent
    return Path(base) / Path(*parts)


def default_static_dir() -> Optional[Path]:
    """Default location of the bundled Flutter web build."""
    candidate = resource_path("app", "build", "web")
    return candidate if candidate.is_dir() else None


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
            - calibration state
      - the set of connected WebSocket clients

        Main thread: runs `main_loop()`, which drives camera frames.
    Background thread: runs the asyncio event loop hosting the websocket
                       server.
    """

    def __init__(self, port: int = 8765, log_path: Optional[str] = None,
                 static_dir: Optional[Path] = None):
        self.port = port
        self.log_path = log_path
        self.static_dir = static_dir
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

    def _broadcast_calibration_progress(self, phase: str, point: int, total: int,
                                        fx: Optional[float] = None,
                                        fy: Optional[float] = None) -> None:
        payload = {
            "type": "calibration_progress",
            "phase": phase,
            "point": point,
            "total": total,
        }
        if fx is not None and fy is not None:
            payload["x"] = fx
            payload["y"] = fy
        self._broadcast_threadsafe(payload)

    # ------------------------------------------------------------------ #
    # Phase 0 — face positioning (runs on the main thread)
    # ------------------------------------------------------------------ #
    def _positioning_phase(self):
        """Pre-calibration face alignment. Runs silently and auto-advances
        after POSITIONING_HOLD_SEC of continuous all-green, with a
        POSITIONING_MAX_SEC fallback so calibration never hangs."""
        print("[ws_server] Phase 0: positioning")
        self._broadcast_calibration_progress(
            "positioning", 0, len(CALIB_MAP_PTS)
        )

        t_ok_start = None
        t_phase_start = time.perf_counter()
        target_period = 1.0 / 30.0
        while True:
            loop_start = time.perf_counter()
            if time.perf_counter() - t_phase_start >= POSITIONING_MAX_SEC:
                return

            ret, frame = self.cap.read()
            if not ret:
                time.sleep(0.01)
                continue
            feats, _blink, pose, _mar = self.pipeline.extract(frame)

            face_ok = feats is not None
            if pose is not None:
                yaw, pitch, _roll, tx, ty, tz = pose.tolist()
                centered = abs(tx) <= POS_TX_MAX and abs(ty) <= POS_TY_MAX
                dist_ok = POS_TZ_MIN <= abs(tz) <= POS_TZ_MAX
                orient_ok = abs(yaw) <= POS_YAW_MAX and abs(pitch) <= POS_PITCH_MAX
            else:
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

            elapsed = time.perf_counter() - loop_start
            time.sleep(max(0.0, target_period - elapsed))

    # ------------------------------------------------------------------ #
    # Calibration (runs on the main thread)
    # ------------------------------------------------------------------ #
    def _run_calibration(self):
        """Blocking calibration. Forwards progress events to all clients."""
        print("[ws_server] Calibration started")
        self.open_camera()

        # Reset the existing pipeline for a fresh calibration run. We
        # deliberately do NOT construct a new GazePipeline here: on Windows a
        # second MediaPipe FaceLandmarker load mangles the absolute model path
        # (errno 22). reset_calibration() reuses the already-loaded landmarker.
        self.pipeline.reset_calibration()

        # Phase 0 — let the user align their face before the dots start.
        self._positioning_phase()

        total_calib = len(CALIB_MAP_PTS)
        target_period = 1.0 / 60.0

        # ---- Phase 1: calibration ----
        for i, (fx, fy) in enumerate(CALIB_MAP_PTS):
            tgt_px = (int(fx * WINDOW_W), int(fy * WINDOW_H))
            self._broadcast_calibration_progress(
                "calibrating", i + 1, total_calib, fx, fy
            )
            t_start = time.perf_counter()
            while time.perf_counter() - t_start < CALIB_DWELL_SEC:
                loop_start = time.perf_counter()
                ret, frame = self.cap.read()
                if not ret:
                    time.sleep(0.01)
                    continue
                feats, blink, pose, mar = self.pipeline.extract(frame)
                mouth_open = mar is not None and mar > MAR_OPEN
                if (feats is not None and not blink and not mouth_open and
                        time.perf_counter() - t_start >= CALIB_WARMUP_SEC):
                    self.pipeline.add_calibration_sample(feats, tgt_px, pose)
                elapsed = time.perf_counter() - loop_start
                time.sleep(max(0.0, target_period - elapsed))

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
            self._broadcast_calibration_progress(
                "bias", j + 1, len(BIAS_PTS), fx, fy
            )
            t_start = time.perf_counter()
            while time.perf_counter() - t_start < BIAS_DWELL_SEC:
                loop_start = time.perf_counter()
                ret, frame = self.cap.read()
                if not ret:
                    time.sleep(0.01)
                    continue
                feats, blink, pose, mar = self.pipeline.extract(frame)
                mouth_open = mar is not None and mar > MAR_OPEN
                if (feats is not None and not blink and not mouth_open and
                        time.perf_counter() - t_start >= BIAS_WARMUP_SEC):
                    self.pipeline.add_bias_sample(feats, tgt_px, pose)
                elapsed = time.perf_counter() - loop_start
                time.sleep(max(0.0, target_period - elapsed))

        self.pipeline.fit_bias()
        self.pipeline.reset_smoothing()

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

                elapsed = time.perf_counter() - t0
                time.sleep(max(0.0, target_period - elapsed))
        finally:
            self.close_camera()
            self.close_log()
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
                elif mtype == "shutdown":
                    # Client-requested server shutdown (Quit button in the
                    # Flutter app). Ack first, then flag the main loop to
                    # exit on its next tick.
                    try:
                        await ws.send(json.dumps({"type": "shutting_down"}))
                    except Exception:
                        pass
                    print("[ws_server] Shutdown requested by client.")
                    self._stop = True
        except websockets.ConnectionClosed:
            pass
        finally:
            self.clients.discard(ws)
            print(f"[ws_server] Client disconnected "
                  f"({len(self.clients)} remaining)")

    # ------------------------------------------------------------------ #
    # HTTP static file serving (so the bundled Flutter web app is served
    # by the same process / port as the WebSocket).
    # ------------------------------------------------------------------ #
    def _http_response(self, connection, request):
        """websockets `process_request` hook.

        Return a Response for plain HTTP GETs (serve a static file); return
        None to let the request continue as a WebSocket upgrade.
        """
        # If the request is a WebSocket handshake, let it through.
        if request.headers.get("Upgrade", "").lower() == "websocket":
            return None
        def _resp(status: int, reason: str, mime: str, body: bytes) -> Response:
            h = Headers()
            h["Content-Type"] = mime
            h["Content-Length"] = str(len(body))
            h["Cache-Control"] = "no-cache"
            # Required for Flutter web's CanvasKit / WASM SharedArrayBuffer.
            h["Cross-Origin-Opener-Policy"] = "same-origin"
            h["Cross-Origin-Embedder-Policy"] = "require-corp"
            return Response(status, reason, h, body)

        if self.static_dir is None:
            return _resp(404, "Not Found", "text/plain",
                         b"static dir not set")

        # Normalize path: "/", "/index.html", "/assets/foo.png"
        rel = request.path.lstrip("/").split("?")[0] or "index.html"
        # Prevent path traversal — resolve and ensure it stays under static_dir.
        target = (self.static_dir / rel).resolve()
        try:
            target.relative_to(self.static_dir.resolve())
        except ValueError:
            return _resp(403, "Forbidden", "text/plain", b"forbidden")
        if target.is_dir():
            target = target / "index.html"
        if not target.is_file():
            return _resp(404, "Not Found", "text/plain",
                         f"not found: {rel}".encode())

        mime, _ = mimetypes.guess_type(str(target))
        if mime is None:
            mime = "application/octet-stream"
        return _resp(200, "OK", mime, target.read_bytes())

    async def _serve(self):
        self._aio_loop = asyncio.get_running_loop()
        msg = f"ws://0.0.0.0:{self.port}"
        if self.static_dir is not None:
            msg += f"  + HTTP static from {self.static_dir}"
        print(f"[ws_server] Listening on {msg}")
        async with websockets.serve(
            self.handle, "0.0.0.0", self.port,
            process_request=self._http_response,
        ):
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
    p.add_argument(
        "--static-dir", type=str, default=None,
        help="directory to serve over HTTP (defaults to the bundled "
             "Flutter web build if present). Pass empty string to disable.",
    )
    args = p.parse_args()

    if args.static_dir is None:
        static_dir = default_static_dir()
    elif args.static_dir == "":
        static_dir = None
    else:
        static_dir = Path(args.static_dir).resolve()
        if not static_dir.is_dir():
            print(f"[ws_server] --static-dir {static_dir} not found; "
                  "HTTP serving disabled.")
            static_dir = None

    server = GazeServer(port=args.port, log_path=args.log,
                        static_dir=static_dir)
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
