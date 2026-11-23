"""Render the actual SwiftUI controls and their idle relock; does not synthesize touch gestures."""
import argparse
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--simctl", required=True)
    parser.add_argument("--watch", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    bundle = "io.github.shikanon.wristjournal.watchkitapp"

    def run(*values):
        result = subprocess.run([args.simctl, *values], capture_output=True, text=True)
        print(result.stdout, end="", flush=True)
        if result.stderr:
            print(result.stderr, end="", flush=True)
        result.check_returncode()
        return result.stdout.strip()

    root = Path(run("get_app_container", args.watch, bundle, "data")) / "Library/Application Support/WristJournalRecordingTests"
    state_path = root / "recording-ui-state.json"

    def wait_mode(mode):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = json.loads(state_path.read_text()) if state_path.exists() else {}
            if state.get("mode") == mode and state.get("active") and not state.get("reduced"):
                return state
            time.sleep(0.1)
        raise RuntimeError(f"SwiftUI did not render {mode}")

    run("privacy", args.watch, "grant", "microphone", bundle)
    state_path.unlink(missing_ok=True)
    run("launch", "--terminate-running-process", args.watch, bundle,
        "-journal-recording-ui", "-journal-recording-reset", "-journal-recording-fixture",
        "-journal-recording-preview", "-journal-recording-controls-preview")
    wait_mode("controls")
    time.sleep(0.25)  # Allow the committed SwiftUI state to reach the compositor.
    run("io", args.watch, "screenshot", str(output / "watch-recording-controls.png"))
    wait_mode("locked")
    time.sleep(0.25)
    run("io", args.watch, "screenshot", str(output / "watch-recording-locked.png"))
    (output / "watch-recording-render.json").write_text(json.dumps({
        "passed": True, "nativeSwiftUIRendered": True, "idleRelockExecuted": True,
        "touchGesturesTested": False, "programmaticUnlock": True,
        "microphoneCaptureTested": False, "injectedActiveScene": True
    }, indent=2))
    run("launch", "--terminate-running-process", args.watch, bundle,
        "-journal-recording-ui", "-journal-recording-reset")
    time.sleep(1)
    run("io", args.watch, "screenshot", str(output / "watch-recording-home.png"))
    run("privacy", args.watch, "revoke", "microphone", bundle)
    run("launch", "--terminate-running-process", args.watch, bundle,
        "-journal-recording-ui", "-journal-recording-reset", "-journal-recording-preview")
    time.sleep(1)
    run("io", args.watch, "screenshot", str(output / "watch-recording-permission-denied.png"))
    print("PASS: native render and idle relock (programmatic unlock)", flush=True)


if __name__ == "__main__":
    main()
