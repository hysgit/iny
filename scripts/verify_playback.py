"""Verify actual persisted iOS playback state after the XCUITest run."""
import json
from pathlib import Path
import shutil
import subprocess

records = json.loads(Path("build/previews/launches.json").read_text())
device = next(item["udid"] for item in records if item["family"] == "iPhone")


def container(identifier):
    return Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", device, identifier, "data"], text=True).strip())


library = json.loads((container("net.icycloud.iny") / "Documents/Library/library.json").read_text())
item = next(item for item in library["items"] if item["title"] == "Iny 播放验收样片")
if item["position"] <= 0 or item["duration"] <= 0:
    raise RuntimeError("Actual playback progress was not persisted")
runner = container("net.icycloud.iny.uitests.xctrunner")
image = next(runner.rglob("Iny-playback.png"))
shutil.copyfile(image, "build/previews/Iny-playback-iphone.png")
result = {"position": item["position"], "duration": item["duration"], "lastPlayedAt": item.get("lastPlayedAt"), "uiTest": "real VLC playback, pause and close"}
Path("build/previews/playback-result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
print(json.dumps(result, indent=2))
