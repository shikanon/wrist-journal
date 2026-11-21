"""Run synthetic daily pipelines on booted iOS/watchOS simulators; no API credentials required."""
import argparse
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--simctl", required=True)
    parser.add_argument("--phone", required=True)
    parser.add_argument("--watch", required=True)
    parser.add_argument("--phone-app", required=True)
    parser.add_argument("--watch-app", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)

    def run(*values):
        result = subprocess.run([args.simctl, *values], capture_output=True, text=True, check=True)
        if result.stdout:
            print(result.stdout.strip(), flush=True)
        if result.stderr:
            print(result.stderr.strip(), flush=True)
        return result.stdout.strip()

    phone_bundle = "io.github.shikanon.wristjournal"
    watch_bundle = phone_bundle + ".watchkitapp"
    run("install", args.phone, args.phone_app)
    run("install", args.watch, args.watch_app)
    run("privacy", args.watch, "revoke", "microphone", watch_bundle)

    def scenario(device, bundle, root, name, launch_args):
        container = Path(run("get_app_container", device, bundle, "data"))
        result_path = container / "Library/Application Support" / root / "simulation-result.json"
        result_path.unlink(missing_ok=True)
        run("launch", "--terminate-running-process", device, bundle, *launch_args)
        deadline = time.monotonic() + 30
        while not result_path.exists() and time.monotonic() < deadline:
            time.sleep(0.25)
        if not result_path.exists():
            raise RuntimeError(f"{name}: app did not write simulation evidence in 30 seconds")
        result = json.loads(result_path.read_text())
        (output / f"{name}.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
        run("io", device, "screenshot", str(output / f"{name}.png"))
        if result.get("passed") is not True:
            raise RuntimeError(f"{name}: {result}")
        print(f"PASS: {name}: {json.dumps(result, ensure_ascii=False)}", flush=True)

    base = ["-journal-fixture", "-journal-fixture-reset", "-journal-simulation-run"]
    scenario(args.phone, phone_bundle, "WristJournalUITests", "phone-daily-cleanup", base)
    scenario(args.phone, phone_bundle, "WristJournalUITests", "phone-restart-review",
             ["-journal-fixture", "-journal-fixture-verify-restart"])
    scenario(args.phone, phone_bundle, "WristJournalUITests", "phone-backup-failure",
             base + ["-journal-fixture-cloud-failure"])
    scenario(args.watch, watch_bundle, "WristJournalWatchUITests", "watch-permission-and-purge",
             ["-journal-watch-simulation"])
    print("PASS: all four simulator scenarios", flush=True)


if __name__ == "__main__":
    main()
