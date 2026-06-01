# -*- mode: python ; coding: utf-8 -*-
"""
PyInstaller spec for the AAC desktop app.

Bundles:
  - launcher.py + ws_server.py + gaze_pipeline.py + head_pose.py
  - the Flutter web build (app/build/web/) under app/build/web/ in the bundle
  - mediapipe data files (.tflite, .binarypb, model assets)
  - eyetrax package
  - the cached face_landmarker.task model (so the user has no first-run download)
  - sklearn + scipy hidden submodules

Build:
    cd backend
    .venv/bin/pyinstaller --noconfirm aac_app.spec

Output: dist/AAC.app  (macOS)  /  dist/AAC/AAC.exe  (Windows)
"""

import os
import sys
from pathlib import Path

from PyInstaller.utils.hooks import (
    collect_data_files,
    collect_submodules,
    collect_dynamic_libs,
)


# --- paths ------------------------------------------------------------------ #
PROJECT_ROOT = Path(SPECPATH).resolve().parent   # …/eye-tracking-project
BACKEND_DIR = PROJECT_ROOT / "backend"
WEB_BUILD = PROJECT_ROOT / "app" / "build" / "web"

if not WEB_BUILD.is_dir():
    raise SystemExit(
        f"[aac_app.spec] Flutter web build not found at {WEB_BUILD}.\n"
        f"Run `cd app && flutter build web --release` first."
    )

# Bundled FaceLandmarker model location. We ship it from the eyetrax cache
# (downloaded once via the standalone benchmark) so the .app is fully offline.
FACE_MODEL = Path.home() / ".cache" / "eyetrax" / "mediapipe" / "face_landmarker.task"
if not FACE_MODEL.is_file():
    raise SystemExit(
        f"[aac_app.spec] face_landmarker.task not found at {FACE_MODEL}.\n"
        "Run the standalone benchmark once (gaze_test_eyetrax.py) so eyetrax "
        "downloads it, then re-run this build."
    )


# --- data files ------------------------------------------------------------- #
datas = []
# Flutter web bundle — under app/build/web/ inside the .app so resource_path()
# can find it via the same relative path as in dev.
datas += [(str(WEB_BUILD), "app/build/web")]
# Ship the FaceLandmarker model inside the bundle. We point eyetrax at it via
# the EYETRAX_FACE_LANDMARKER_MODEL env var, set in launcher startup.
datas += [(str(FACE_MODEL), "models/eyetrax")]
# mediapipe package data (modules/*.tflite, *.binarypb, etc.)
datas += collect_data_files("mediapipe")
# eyetrax package data — includes_py_files because eyetrax/models/__init__.py
# auto-discovers model implementations by walking the directory at runtime
# (`Path(__file__).parent.iterdir()`), so the .py files must exist on disk.
datas += collect_data_files("eyetrax", include_py_files=True)
# sklearn / scipy occasional data files
datas += collect_data_files("sklearn")


# --- hidden imports --------------------------------------------------------- #
hiddenimports = []
hiddenimports += collect_submodules("mediapipe")
hiddenimports += collect_submodules("sklearn")
hiddenimports += collect_submodules("scipy")
# eyetrax uses lazy `__getattr__` in __init__, so PyInstaller can't trace the
# submodules from `from eyetrax import GazeEstimator`. Collect them explicitly.
hiddenimports += collect_submodules("eyetrax")
# Without these, the bundled app sometimes fails to load the cv2 / pygame deps.
hiddenimports += [
    "websockets",
    "websockets.legacy",
    "websockets.asyncio.server",
    "websockets.http11",
    "websockets.datastructures",
]


# --- binaries (native libs) ------------------------------------------------- #
binaries = []
binaries += collect_dynamic_libs("mediapipe")
binaries += collect_dynamic_libs("cv2")


# --- analysis --------------------------------------------------------------- #
a = Analysis(
    [str(BACKEND_DIR / "launcher.py")],
    pathex=[str(BACKEND_DIR)],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    excludes=["tkinter", "matplotlib.tests", "scipy.tests"],
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="AAC",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,           # keep stdout visible so users can see errors
    disable_windowed_traceback=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="AAC",
)


# --- macOS .app bundle ------------------------------------------------------ #
if sys.platform == "darwin":
    app = BUNDLE(
        coll,
        name="AAC.app",
        icon=None,
        bundle_identifier="com.maastricht.aac",
        info_plist={
            # macOS 10.15+: camera access prompt.
            "NSCameraUsageDescription":
                "AAC needs camera access to track your gaze for symbol selection.",
            # Required so the .app can host a local HTTP server on localhost.
            "NSAppTransportSecurity": {
                "NSAllowsLocalNetworking": True,
            },
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "0.1.0",
            "LSMinimumSystemVersion": "11.0",
        },
    )
