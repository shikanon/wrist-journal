"""Run actual Watch analyzer on synthetic audio, then hand its serialized result to iOS."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    for name in ["simctl", "phone", "watch", "phone-app", "watch-app", "output"]:
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)

    def run(*values):
        result = subprocess.run([args.simctl, *values], capture_output=True, text=True)
        print(result.stdout, end="", flush=True)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout.strip()

    phone = "io.github.shikanon.wristjournal"
    watch = phone + ".watchkitapp"
    run("install", args.phone, args.phone_app)
    run("install", args.watch, args.watch_app)
    containers = {}
    for device, bundle in [(args.watch, watch), (args.phone, phone)]:
        containers[bundle] = Path(run("get_app_container", device, bundle, "data"))
    for device, bundle, name in [(args.watch, watch, "watch-processing"), (args.phone, phone, "phone-processing")]:
        container = containers[bundle]
        root = container / "Library/Application Support/WristJournalProcessingTests"
        if bundle == phone:
            documents = container / "Documents"
            documents.mkdir(exist_ok=True)
            shutil.copyfile(containers[watch] / "Library/Application Support/WristJournalProcessingTests/watch-result.json",
                            documents / "watch-result.json")
        (root / "simulation-result.json").unlink(missing_ok=True)
        preview = ["-journal-sources-preview"] if bundle == phone else []
        run("launch", "--terminate-running-process", device, bundle, "-journal-processing-simulation", *preview)
        deadline = time.monotonic() + 45
        while not (root / "simulation-result.json").exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        result = json.loads((root / "simulation-result.json").read_text())
        (output / (name + ".json")).write_text(json.dumps(result, ensure_ascii=False, indent=2))
        assert result.get("passed") is True, result
        print("PASS:", name, result, flush=True)
        if bundle == phone:
            render_path = root / "source-ui-result.json"
            deadline = time.monotonic() + 10
            render = {}
            while time.monotonic() < deadline:
                render = json.loads(render_path.read_text()) if render_path.exists() else {}
                if render.get("audioCleaned") and render.get("quote"):
                    break
                time.sleep(0.1)
            assert render.get("audioCleaned") and render.get("quote"), render
            (output / "phone-source-render.json").write_text(json.dumps(render, ensure_ascii=False, indent=2))
            time.sleep(0.8)
            run("io", device, "screenshot", str(output / "phone-source-review.png"))


if __name__ == "__main__":
    main()
