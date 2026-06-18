#!/usr/bin/env bash
# Build the AAC desktop .app on macOS.
#
# Prereqs:
#   - Python 3.11 + the backend venv at backend/.venv (see README).
#   - Flutter SDK (for the web build).
#   - The face_landmarker.task cached at ~/.cache/eyetrax/mediapipe/.
#     Run gaze_test_eyetrax.py once if it's missing — eyetrax downloads it.
#
# Output: backend/dist/AAC.app  (~630 MB unsigned, ad-hoc signed).

set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd -- "$SCRIPT_DIR/.." && pwd )"
VENV="$SCRIPT_DIR/.venv"

if [ ! -x "$VENV/bin/python" ]; then
  echo "ERROR: $VENV/bin/python not found. Set up the venv first:"
  echo "  cd backend && python3.11 -m venv .venv && source .venv/bin/activate"
  echo "  pip install -r requirements.txt pyinstaller"
  exit 1
fi

# 1. Build the Flutter web app.
echo "==> Building Flutter web (release)"
( cd "$PROJECT_ROOT/app" && flutter build web --release )

# 2. PyInstaller — produces backend/dist/AAC.app and backend/dist/AAC/.
echo "==> Running PyInstaller"
( cd "$SCRIPT_DIR" && "$VENV/bin/pyinstaller" --noconfirm aac_app.spec )

# 3. Strip extended attrs that block codesign, then ad-hoc sign so Gatekeeper
#    treats the bundle as locally-trusted (still requires right-click → Open
#    on first launch).
echo "==> Stripping xattrs + ad-hoc signing"
xattr -cr "$SCRIPT_DIR/dist/AAC.app"
codesign --force --deep --sign - "$SCRIPT_DIR/dist/AAC.app" || true

echo
echo "==> Built: $SCRIPT_DIR/dist/AAC.app"
echo "    Run:  open $SCRIPT_DIR/dist/AAC.app"
echo "    (First launch: right-click → Open, then click 'Open' in the prompt.)"
