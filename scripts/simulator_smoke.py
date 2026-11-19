"""Launch Iny on one iPhone and one iPad simulator and retain actual UI images."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import shutil
import uuid


def command(*args):
    print("simctl " + args[0], flush=True)
    timeout = 600 if args[0] == "bootstatus" else 120
    try:
        return subprocess.check_output(["xcrun", "simctl", *args], text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        print("Timed out in simctl " + args[0], flush=True)
        if error.output:
            print(str(error.output)[-2000:], flush=True)
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("build/previews"))
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--family", choices=["all", "iPhone", "iPad"], default="all")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    devices = json.loads(command("list", "devices", "available", "--json"))["devices"]
    candidates = [device for runtime in sorted(devices, reverse=True) if ".iOS-" in runtime for device in devices[runtime] if device.get("isAvailable")]
    records = []
    for family in (["iPhone", "iPad"] if args.family == "all" else [args.family]):
        device = next((device for device in candidates if device["name"].startswith(family)), None)
        if not device:
            raise RuntimeError("No available " + family + " simulator")
        identifier = device["udid"]
        booted_here = device["state"] != "Booted"
        if booted_here:
            command("boot", identifier)
        try:
            command("bootstatus", identifier, "-b")
            command("install", identifier, str(args.app.resolve()))
            launched = command("launch", "--terminate-running-process", identifier, "net.icycloud.iny")
            time.sleep(4)
            image = args.output / ("Iny-" + family.lower() + ".png")
            command("io", identifier, "screenshot", str(image))
            records.append({"device": device["name"], "family": family, "udid": identifier, "launch": launched.strip(), "screenshot": image.name})
            if args.fixture and family == "iPhone":
                # 先停止应用，再给独占的 CI 模拟器准备样片，避免与应用事务并发写索引。
                command("terminate", identifier, "net.icycloud.iny")
                container = Path(command("get_app_container", identifier, "net.icycloud.iny", "data").strip())
                library = container / "Documents/Library"
                library.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(args.fixture, library / "playback.mp4")
                item = {"id": str(uuid.uuid4()).upper(), "title": "Iny 播放验收样片", "localFilename": "playback.mp4",
                        "overview": "", "duration": 0, "position": 0, "watched": False, "favorite": False,
                        "addedAt": time.time() - 978307200, "mediaType": "movie"}
                (library / "library.json").write_text(json.dumps({"version": 1, "revision": 1, "items": [item], "sources": []}), encoding="utf-8")
        finally:
            if booted_here:
                command("shutdown", identifier)
    (args.output / "launches.json").write_text(json.dumps(records, indent=2), encoding="utf-8")
    print(json.dumps(records, indent=2))


if __name__ == "__main__":
    main()
