"""
Single-binary entry point for the bundled AAC desktop app.

When PyInstaller builds the .app / .exe, this is the script the OS runs
when the user double-clicks the icon. It:

  1. Opens the user's default browser at http://localhost:8765/ on a delay,
     so the WebSocket+HTTP server has time to bind first.
  2. Hands control to ws_server.main() — which owns the main thread
     because pygame/SDL requires it on macOS.

The static-file directory and the WebSocket both live on port 8765, so
the bundled Flutter web build is served by the same process that streams
gaze events.
"""

from __future__ import annotations

import os
import sys
import threading
import time
import webbrowser

# When packed by PyInstaller the bundle dir is a parent of this script in
# sys.path; the backend modules import as usual.
from ws_server import main as ws_main, default_static_dir, resource_path


def _set_bundled_face_model_env() -> None:
    """When running inside the PyInstaller bundle, point eyetrax at the
    face_landmarker.task we shipped in `models/eyetrax/`. Otherwise eyetrax
    tries to download it on first use, which fails offline.
    """
    if "EYETRAX_FACE_LANDMARKER_MODEL" in os.environ:
        return  # user override — respect it
    bundled = resource_path("models", "eyetrax", "face_landmarker.task")
    if bundled.is_file():
        os.environ["EYETRAX_FACE_LANDMARKER_MODEL"] = str(bundled)
        print(f"[launcher] Using bundled FaceLandmarker model: {bundled}")


def open_browser_later(url: str, delay_sec: float = 1.5) -> None:
    """Open the user's default browser to `url` after `delay_sec`."""
    def _go():
        time.sleep(delay_sec)
        try:
            webbrowser.open(url, new=2)
            print(f"[launcher] Opened browser at {url}")
        except Exception as e:
            print(f"[launcher] Failed to open browser: {e}")
            print(f"[launcher] Open this URL manually: {url}")
    t = threading.Thread(target=_go, daemon=True, name="launcher-browser")
    t.start()


def main() -> None:
    # Default port — must match ws_server.main()'s default. If the user
    # passes --port we honor it (ws_server.main parses argv itself).
    port = 8765
    for i, a in enumerate(sys.argv):
        if a == "--port" and i + 1 < len(sys.argv):
            try:
                port = int(sys.argv[i + 1])
            except ValueError:
                pass

    _set_bundled_face_model_env()

    static = default_static_dir()
    if static is None:
        print("[launcher] WARNING: bundled Flutter web build not found. "
              "The server will still run as a WebSocket-only backend.")

    print(f"[launcher] Starting AAC desktop app on http://localhost:{port}/")
    open_browser_later(f"http://localhost:{port}/")
    # ws_server.main() blocks on the pygame/camera loop until Ctrl-C or
    # the window closes. It also parses --port/--log/--static-dir from argv.
    ws_main()


if __name__ == "__main__":
    main()
