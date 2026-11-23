"""Watch recording lifecycle evidence; --fixture uses encoded audio, not live microphone capture."""
import argparse
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--simctl", required=True)
    parser.add_argument("--watch", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--fixture", action="store_true")
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

    def evidence(path, name):
        deadline = time.monotonic() + 30
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(0.25)
        if not path.exists():
            raise RuntimeError(f"{name}: no result in 30 seconds")
        result = json.loads(path.read_text())
        (output / f"{name}.json").write_text(json.dumps(result, indent=2, ensure_ascii=False))
        if result.get("passed") is not True:
            raise RuntimeError(f"{name}: {result}")
        print(f"PASS: {name}", flush=True)

    run("install", args.watch, args.app)
    run("privacy", args.watch, "grant", "microphone", bundle)
    container = Path(run("get_app_container", args.watch, bundle, "data"))
    root = container / "Library/Application Support/WristJournalRecordingTests"
    fixture = ["-journal-recording-fixture"] if args.fixture else []
    run("launch", "--terminate-running-process", args.watch, bundle,
        "-journal-recording-simulation", "-journal-recording-reset", *fixture)
    evidence(root / "simulation-result.json", "watch-recording-lifecycle")
    run("launch", "--terminate-running-process", args.watch, bundle,
        "-journal-recording-ui", "-journal-recording-verify", *fixture)
    evidence(root / "cold-start-result.json", "watch-recording-cold-start")
    time.sleep(1)  # Cold-start evidence is written before SwiftUI finishes its first visible frame.
    run("io", args.watch, "screenshot", str(output / "watch-recording-recovery.png"))
    run("privacy", args.watch, "revoke", "microphone", bundle)
    permission_result = container / "Library/Application Support/WristJournalWatchUITests/simulation-result.json"
    permission_result.unlink(missing_ok=True)
    run("launch", "--terminate-running-process", args.watch, bundle, "-journal-watch-simulation")
    evidence(permission_result, "watch-permission-and-purge")


if __name__ == "__main__":
    main()
