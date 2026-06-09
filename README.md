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

| Path | Role |
|---|---|
| `app/` | Flutter AAC frontend (gaze cursor, dwell-to-select board, calibration UI, mouse/sim/websocket input modes) |
| `backend/gaze_test_eyetrax.py` | End-to-end benchmark: calibration → bias → evaluation → free tracking |
| `backend/benchmark_pipeline.py` | Benchmark for the live `GazePipeline` (kernel ridge + pose-aware bias + MAR) — A/B counterpart to the script above |
| `backend/gaze_pipeline.py` | Reusable `GazePipeline` class wrapping EyeTrax + bias + EMA + pose gate |
| `backend/ws_server.py` | WebSocket + HTTP server: streams gaze events and serves the bundled Flutter web app |
| `backend/launcher.py` | Single-binary entry point for the desktop app (PyInstaller) |
| `backend/aac_app.spec` | PyInstaller spec — builds the `.app` / `.exe` |
| `backend/build_macos.sh`, `build_windows.bat` | One-shot build scripts |
| `backend/head_pose.py` | MediaPipe Face Mesh + `cv2.solvePnP` head-pose estimator (6-DoF) |
| `backend/requirements.txt` | Pinned Python dependencies |
| `PHASE3_PLAN.md` | Phase 3 integration plan (backend ↔ frontend wiring) |
| `RESULTS.md` | Full benchmark writeup, library comparison, negative results |
| `Group_10_Project_Plan.pdf` | Original project plan |

## Desktop app (one-click install)

The primary user-facing artefact is a single installable desktop bundle —
no Python, no Flutter SDK, no terminals on the user's machine.

> **Download:** [Latest release → v1.0](https://github.com/GabrielPadure/eye-tracking-project/releases/latest)

| OS | File | Size |
|---|---|---|
| Windows | [`AAC.exe`](https://github.com/GabrielPadure/eye-tracking-project/releases/download/v1.0/AAC.exe) | ~31 MB |

The bundle contains the Python backend (gaze pipeline + WebSocket + HTTP
server), all native dependencies (MediaPipe, OpenCV, scikit-learn, pygame),
the cached `face_landmarker.task` model, and the Flutter web build. The
backend serves the Flutter app over `http://localhost:8765` and streams
gaze events over `ws://localhost:8765` on the same port.

### Using the desktop app

1. Install the bundle (see [Building from source](#building-the-desktop-app-from-source)).
2. Double-click the icon. On first launch:
   - **macOS**: right-click → Open → click *Open* in the Gatekeeper
     prompt (the `.app` is ad-hoc signed, not notarised). Approve the
     camera permission prompt.
   - **Windows**: SmartScreen warns about an unsigned `.exe` — click
     *More info* → *Run anyway*.
3. Your default browser opens at `http://localhost:8765/` showing the
   AAC app. Calibration targets appear inside the app when you start
   calibration.
4. Close the browser tab and Ctrl-C in the terminal (or quit the app
   from the Dock / system tray) to stop.

### Building the desktop app from source

Prereqs: Python 3.11 venv (see [Setup](#setup)), Flutter SDK, and one
prior run of `gaze_test_eyetrax.py` so `face_landmarker.task` is cached
under `~/.cache/eyetrax/mediapipe/`.

**macOS:**
```bash
cd backend
.venv/bin/pip install pyinstaller
./build_macos.sh
# → backend/dist/AAC.app
```

**Windows:**
```cmd
cd backend
.venv\Scripts\pip install pyinstaller
build_windows.bat
REM → backend\dist\AAC\AAC.exe
```

Both scripts run `flutter build web --release` followed by `pyinstaller
aac_app.spec`. The macOS script also strips extended attributes and
ad-hoc signs the bundle so Gatekeeper accepts it.

## Setup

(for development / running the benchmark / hacking on the backend —
**not** needed by end users of the desktop app)

Requires **Python 3.11.x** — MediaPipe 0.10.x does not support 3.12+ on
macOS ARM64.

```bash
cd backend
python3.11 -m venv .venv
#mac:
source .venv/bin/activate
#windows:
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

MediaPipe will download its FaceLandmarker model (~4 MB) into
`~/.cache/eyetrax/mediapipe/face_landmarker.task` on first run.

## Running the benchmark

```bash
cd backend
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

## Running the full AAC app (backend + Flutter)

The Flutter app in `app/` talks to the Python backend over a WebSocket
(default port `8765`). Use two terminals.

### Prerequisites

- **Python venv** set up as in [Setup](#setup) above (`backend/.venv`).
- **Flutter SDK** installed and `flutter doctor` clean.
- **macOS Camera permission** granted to whichever terminal / IDE you run
  `python` from: System Settings → Privacy & Security → Camera.
- Close any other app that may be holding the webcam (Zoom, Teams,
  FaceTime, Photo Booth).

### Step 1 — Start the backend

```bash
cd backend
.venv/bin/python ws_server.py
```

You should see:

```
[ws_server] Opening camera (index 0)…
[ws_server] Camera opened: 1280x720  (test read: ok)
[ws_server] Listening on ws://0.0.0.0:8765
```

| Symptom | Fix |
|---|---|
| `ERROR: cannot open camera` | Grant Camera permission to your terminal in System Settings → Privacy & Security → Camera, then restart. |
| `Camera opened … (test read: FAILED)` | Another app is holding the webcam. Close it. |
| First-run macOS permission popup | Click **Allow**, then restart the server. |

Leave this terminal running.

### Step 2 — Start the Flutter app

In a second terminal:

```bash
cd app
flutter pub get          # one-time
flutter run -d chrome    # or: -d macos, -d <device-id>
```

Chrome is the easiest target for development. For a real tablet, use
`flutter devices` to find the device id, then `flutter run -d <id>` and
set the host to your laptop's LAN IP (see Step 3).

### Step 3 — Configure connection

In the app: **Home → Settings**.

| Field | Value |
|---|---|
| Host | `localhost` (same machine) **or** the laptop's LAN IP (e.g. `192.168.1.x`) for tablet use |
| Port | `8765` |
| Dwell duration | default `1500` ms |

Values are persisted via `SharedPreferences`, so you only need to set
them once per device.

### Step 4 — Connect

**Home → Board**, then click the **WebSocket** button (wifi icon, top
right of the board screen). The server terminal should print:

```
[ws_server] Client connected (1 total)
```

If it doesn't, check Chrome DevTools (F12) → Console for connection
errors.

### Step 5 — Calibrate

**Home → Calibration → Start Calibration**.

The calibration targets appear inside the app. Server terminal prints:

```
[ws_server] Received: start_calibration
[ws_server] Calibration started
```

Follow ~30 seconds of dots:

1. **13 blue dots** — calibration (Ridge regressor)
2. **5 green dots** — bias measurement (affine correction)

The Flutter UI shows a progress bar throughout. When the server prints
`[ws_server] Calibration complete`, click **Go to Board** in the dialog.

### Step 6 — Use the board

You're now on the AAC board, and the server is streaming gaze
coordinates at ~30 fps. Stare at any tile for the dwell duration
(~1.5 s) — the dwell ring fills and TTS speaks the symbol's label.

The dwell ring **cancels automatically** when the backend reports
`confidence < 0.5` (head outside calibrated pose range) or a blink.

### Step 7 — Stop

`Ctrl-C` in the server terminal; close the Chrome tab. The server
releases the camera and shuts down cleanly.

### Alternative input modes

Useful for development when you don't want to calibrate on every run:

- **Mouse** — the OS mouse cursor drives the gaze cursor; dwell is
  triggered by hovering on a tile. Lets you test the board layout
  without a webcam.
- **Sim** — `GazeSimulatorService` produces a random-walk fake gaze
  through the same pipeline as the real backend.

Both are toggled from the top-right mode selector on the board screen.

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
