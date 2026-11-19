"""Launch Iny on one iPhone and one iPad simulator and retain actual UI images."""
import argparse
import json
from pathlib import Path
import subprocess
import time


def command(*args):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("build/previews"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    devices = json.loads(command("list", "devices", "available", "--json"))["devices"]
    candidates = [device for runtime in sorted(devices, reverse=True) if ".iOS-" in runtime for device in devices[runtime] if device.get("isAvailable")]
    records = []
    for family in ["iPhone", "iPad"]:
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
            records.append({"device": device["name"], "family": family, "launch": launched.strip(), "screenshot": image.name})
        finally:
            if booted_here:
                command("shutdown", identifier)
    (args.output / "launches.json").write_text(json.dumps(records, indent=2), encoding="utf-8")
    print(json.dumps(records, indent=2))


if __name__ == "__main__":
    main()
