# Phase 3 Implementation Plan — AAC Gaze Tracking (Group 10)

## Context

The project goal is an open-source, webcam-based AAC system for non-speaking users.
- **Phase 1** ✅ — Project plan delivered (PDF)
- **Phase 2** ✅ — Python inference engine built & benchmarked: EyeTrax 0.4.0 + 13-point calibration + affine bias correction + EMA smoothing (α=0.3) + pose-gated confidence → **1.50° mean angular error** (meets the <2° target). Code lives in `gaze_test_eyetrax.py` and `head_pose.py`.
- **Phase 3** 🔲 — **Integration + evaluation + final report.** The Flutter frontend exists on `origin/dev` (`app/`) but is **not yet integrated** with the Python backend. The backend has no WebSocket server yet.

**Project plan deliverables for Phase 3 (D5, D6, D7):**
- **D5** — Optimized Tracker / integrated Flutter app (since Phase 2 met the accuracy target, this means full integration)
- **D6** — Evaluation: comparative accuracy, precision, robustness (head movement, glasses)
- **D7** — Final project report

**Gantt timeline (from project plan):**
- Integrate eye tracking + Cboard + Flutter: **6/2/26–6/29/26** (Gabriel & Vasile)
- Test and evaluate: **6/1/26–7/1/26** (Dan & Mathijs)
- Finalize testing / gather results: **6/1/26–7/7/26** (Everyone)
- General revision: **6/1/26–7/15/26** (Everyone)
- Write report: **6/29/26–7/15/26** (Everyone)
- Final presentation: **8/5/26–9/1/26** (Everyone)

---

## What is Already Done

### Python Backend
| Item | Status |
|------|--------|
| EyeTrax Ridge regressor + 13-pt calibration | ✅ Done (`gaze_test_eyetrax.py`) |
| Affine bias correction (5-anchor) | ✅ Done |
| EMA smoothing (α=0.3) | ✅ Done |
| Pose-gated confidence (6-DoF, z=3.0) | ✅ Done (`head_pose.py`) |
| Benchmark metrics (JSON/CSV output) | ✅ Done |
| WebSocket server | ❌ Not started |

### Flutter Frontend (`app/` on `origin/dev`)
| Item | Status |
|------|--------|
| Home, Board, Calibration, Settings screens | ✅ Done |
| WebSocket client (`EyeTrackingService`) parses `{"x":…,"y":…}` | ✅ Done (wire-compatible) |
| Mouse-mode & simulator gaze for dev testing | ✅ Done |
| Dwell-to-click on 2×2 symbol grid with TTS | ✅ Done |
| Gaze cursor overlay + connection badge | ✅ Done |
| Backend calibration integration (CalibrationScreen) | ❌ TODO stub only |
| Real camera preview | ❌ TODO placeholder |
| Settings persistence (SharedPreferences) | ❌ TODO |
| Auto-reconnect on WebSocket drop | ❌ TODO |
| Confidence signal handling (drop dwell on low confidence) | ❌ TODO |

---

## Phase 3 Implementation Plan

### Step 1 — Create the Python WebSocket Server (`ws_server.py`)

**New file: `ws_server.py`** (alongside `gaze_test_eyetrax.py`)

This wraps the trained EyeTrax pipeline in a `websockets` server that streams gaze events to the Flutter app.

**Architecture:**
```
Camera → EyeTrax features → Ridge predict → affine correction → EMA smooth
    → pose_confidence → JSON payload → WebSocket broadcast
```

**Protocol — server → Flutter (every processed frame, ~30 fps):**
```json
{"x": 0.45, "y": 0.62, "confidence": 0.92, "blink": false}
```
`x`, `y` are normalized 0.0–1.0 (divide raw px by window size).
`confidence` maps to the pose gate (existing `pose_confidence()` function).
`blink` is the `blink` flag from `est.extract_features()`.

**Protocol — Flutter → server (calibration trigger):**
```json
{"type": "start_calibration"}
```
Server runs the calibration pass internally (pygame window) and responds with:
```json
{"type": "calibration_done"}
```

**Key implementation details:**
- Extract the gaze pipeline from `gaze_test_eyetrax.py` into reusable class (`gaze_pipeline.py`)
- Use `websockets` library (`pip install websockets`)
- Run camera loop in asyncio executor thread (non-blocking)
- Default port: **8765** (matches Flutter `BackendConfig` default)
- Accept connection → run calibration → stream gaze
- Graceful shutdown on disconnect

**Files to modify:**
- `requirements.txt` — add `websockets>=12.0`
- New file: `ws_server.py`

---

### Step 2 — Refactor Python Pipeline into a Reusable Class

Extract core logic from `gaze_test_eyetrax.py` into a `GazePipeline` class that `ws_server.py` can import:

```python
class GazePipeline:
    def __init__(self): ...
    def calibrate(self, targets, dwell_sec): ...   # existing calib logic
    def measure_bias(self, anchors, dwell_sec): ... # existing bias logic
    def process_frame(self, frame) -> dict: ...     # returns {"x","y","confidence","blink"}
    def close(self): ...
```

**File:** `gaze_pipeline.py` (new)
`gaze_test_eyetrax.py` — keep as-is (standalone benchmark), can optionally import `GazePipeline`

---

### Step 3 — Flutter: Wire Calibration Screen to Backend

**File:** `app/lib/screens/calibration_screen.dart`

Currently `CalibrationScreen` has a `// TODO: Send calibration point to backend` stub.

**Recommended approach (Python-side calibration UI):**
1. Flutter sends `{"type": "start_calibration"}` to the WebSocket
2. Python server runs its calibration phases (pygame window) and emits progress: `{"type": "calibration_progress", "point": 3, "total": 13}`
3. Flutter shows a "Calibration in progress…" overlay while waiting
4. On `{"type": "calibration_done"}`, Flutter navigates to the board

This avoids duplicating the calibration UI in Dart.

**Files to modify:** `app/lib/screens/calibration_screen.dart`, `app/lib/services/eye_tracking_service.dart`

---

### Step 4 — Flutter: Confidence-Aware Dwell Logic

**File:** `app/lib/services/eye_tracking_service.dart`

Update `_onMessage` to parse the extended payload:
```dart
final point = GazePoint(
  x: (data['x'] as num).toDouble().clamp(0.0, 1.0),
  y: (data['y'] as num).toDouble().clamp(0.0, 1.0),
  confidence: (data['confidence'] as num?)?.toDouble() ?? 1.0,
  blink: data['blink'] as bool? ?? false,
  timestamp: DateTime.now(),
);
```

**File:** `app/lib/models/gaze_point.dart` — add `confidence` and `blink` fields.

**File:** `app/lib/widgets/symbol_tile.dart` — if `confidence < 0.5`, call `cancelDwell()` instead of `startDwell()` (prevents false selections when head is outside calibration range).

**File:** `app/lib/providers/gaze_provider.dart` — expose `currentConfidence` so the connection badge can reflect pose-gate status.

---

### Step 5 — Flutter: Auto-Reconnect + Error Handling

**File:** `app/lib/services/eye_tracking_service.dart`

In `_onDone()` and `_onError()` (currently empty stubs):
```dart
void _onDone() {
  // Exponential backoff reconnect: 1s, 2s, 4s… capped at 30s
  _scheduleReconnect();
}
```

Notify `ConnectionProvider` of status changes (it already has `ConnectionStatus` enum: disconnected / connecting / connected).

---

### Step 6 — Flutter: Settings Persistence

**File:** `app/lib/providers/connection_provider.dart`

Add `shared_preferences` package to `pubspec.yaml`. Save/load `BackendConfig` (host, port, dwell duration) on app start and on settings save. Required so the app remembers the laptop's IP address across sessions.

---

### Step 7 — Merge `origin/dev` into `main`

The Flutter app currently lives only on `origin/dev`. Merge into `main` so the Python backend and Flutter app coexist in one branch.

```bash
git checkout main
git merge origin/dev
```

---

### Step 8 — Evaluation (D6): Multi-User Testing

Per the project plan research questions:
- **RQ3**: What impact does wearing glasses have on gaze-tracking performance?
- **RQ4**: How accurate are these methods on standard consumer tablets?

**Protocol:**
1. Run `ws_server.py` on a laptop
2. Connect Flutter app (iPad or Android tablet) via LAN WebSocket
3. Test 2–3 additional participants, **at least 1 wearing glasses**
4. Record per-frame metrics via CSV output (reuse existing logging from `gaze_test_eyetrax.py`)
5. Compare mean angular error / precision across users and conditions

---

### Step 9 — Final Report (D7)

Expand `RESULTS.md` / write the final report covering:
- Full pipeline architecture + all design decisions
- Phase 3 integration results: end-to-end latency (WebSocket round-trip at 30 fps)
- Multi-user evaluation results (Step 8)
- Glasses robustness analysis
- Limitations and future work

---

## Critical Files

| File | Action |
|------|--------|
| `gaze_pipeline.py` | **CREATE** — refactored reusable `GazePipeline` class |
| `ws_server.py` | **CREATE** — WebSocket server wrapping `GazePipeline` |
| `requirements.txt` | **MODIFY** — add `websockets>=12.0` |
| `app/lib/models/gaze_point.dart` | **MODIFY** — add `confidence`, `blink` fields |
| `app/lib/services/eye_tracking_service.dart` | **MODIFY** — parse confidence/blink, add reconnect logic |
| `app/lib/screens/calibration_screen.dart` | **MODIFY** — send calibration trigger, await `calibration_done` |
| `app/lib/providers/gaze_provider.dart` | **MODIFY** — expose `currentConfidence` |
| `app/lib/widgets/symbol_tile.dart` | **MODIFY** — gate dwell on `confidence < 0.5` |
| `app/pubspec.yaml` | **MODIFY** — add `shared_preferences` |
| `app/lib/providers/connection_provider.dart` | **MODIFY** — add settings persistence |

---

## Reusable Existing Code

| Existing code | Reused in |
|---------------|-----------|
| `est`, `pose_est`, `apply_correction()`, `smooth()`, `pose_confidence()` in `gaze_test_eyetrax.py` | Extracted verbatim into `GazePipeline.process_frame()` |
| `EyeTrackingService._onMessage()` WebSocket parser | Extended with `confidence`/`blink` fields |
| `ConnectionProvider.ConnectionStatus` enum | Used for auto-reconnect state machine |
| `SymbolTile.startDwell()` / `cancelDwell()` | Called conditionally on confidence |
| CSV logging from `gaze_test_eyetrax.py` | Ported into `ws_server.py` for evaluation data collection |

---

## Verification / Testing

1. **Smoke test**: Start `ws_server.py` → connect with `websocat ws://localhost:8765` → verify JSON stream at ~30 fps
2. **Simulator mode**: Run Flutter app without backend → confirm dwell-to-click still works in simulator mode
3. **End-to-end**: Start `ws_server.py` → open Flutter app → set host to `localhost` → switch to WebSocket mode → verify gaze cursor moves and dwell triggers TTS
4. **Confidence gate**: Deliberately move head far from camera mid-dwell → confirm tile resets (no false selection)
5. **Reconnect**: Kill `ws_server.py` mid-session → restart → confirm Flutter reconnects automatically
6. **Glasses test**: Repeat calibration + 9-point evaluation with glasses-wearing participant → compare CSV output to baseline

---

## Implementation Order (Priority)

| Priority | Step | Rationale |
|----------|------|-----------|
| 1 | Steps 1–2: `gaze_pipeline.py` + `ws_server.py` | Critical path — nothing else works without the server |
| 2 | Step 4: Confidence-aware dwell | Small Flutter change, big safety improvement |
| 3 | Step 7: Merge dev → main | Get everything in one place |
| 4 | Step 5: Auto-reconnect | Robustness for real-world use |
| 5 | Step 3: Calibration protocol | UX improvement |
| 6 | Step 6: Settings persistence | Convenience |
| 7 | Step 8: Multi-user evaluation | Requires working end-to-end system |
| 8 | Step 9: Final report | Last — synthesizes all results |
