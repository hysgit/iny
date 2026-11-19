"""Download this project's CI artifact and safely retain build output locally."""
import argparse
import io
import json
from pathlib import Path
import urllib.request
import zipfile
from github_ci import credential, NoAuthRedirect

ROOT = Path(__file__).resolve().parents[1]


class RangeArchive(io.RawIOBase):
    def __init__(self, url, length):
        self.url = url
        self.length = length
        self.position = 0

    def seekable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=0):
        self.position = offset if whence == 0 else (self.position + offset if whence == 1 else self.length + offset)
        return self.position

    def read(self, size=-1):
        if size < 0:
            size = self.length - self.position
        if size == 0:
            return b""
        request = urllib.request.Request(self.url, headers={"Range": f"bytes={self.position}-{self.position + size - 1}"})
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status != 206:
                raise RuntimeError("Artifact storage did not honor range request")
            data = response.read()
        self.position += len(data)
        return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run_id", type=int)
    parser.add_argument("--artifact", default="Iny-iOS-build")
    parser.add_argument("--previews-only", action="store_true")
    args = parser.parse_args()
    token = credential()
    opener = urllib.request.build_opener(NoAuthRedirect())

    def get(url):
        request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json"})
        with opener.open(request, timeout=60) as response:
            return response.read()

    listing = json.loads(get(f"https://api.github.com/repos/hysgit/iny/actions/runs/{args.run_id}/artifacts"))
    selected = next(item for item in listing["artifacts"] if item["name"] == args.artifact and not item["expired"])
    if args.previews_only:
        request = urllib.request.Request(selected["archive_download_url"], headers={"Authorization": "Bearer " + token, "Range": "bytes=0-0"})
        with opener.open(request, timeout=30) as response:
            if response.status != 206:
                raise RuntimeError("Artifact storage does not support partial download")
            length = int(response.headers["Content-Range"].split("/")[-1])
            source = RangeArchive(response.geturl(), length)
    else:
        data = get(selected["archive_download_url"])
        source = io.BytesIO(data)
    folder = ROOT / "analysis/cloud" / str(args.run_id) / "artifacts"
    folder.mkdir(parents=True, exist_ok=True)
    retained = []
    with zipfile.ZipFile(source) as archive:
        for member in archive.infolist():
            destination = (folder / member.filename).resolve()
            if not destination.is_relative_to(folder.resolve()) or ((member.external_attr >> 16) & 0o170000) == 0o120000:
                raise RuntimeError("Unsafe artifact archive member")
            if not args.previews_only or member.filename.endswith((".png", "launches.json", "playback-result.json")):
                archive.extract(member, folder)
                retained.append(member.filename)
    print(json.dumps({"run": args.run_id, "artifact": selected["name"], "files": retained, "directory": str(folder)}, indent=2))


if __name__ == "__main__":
    main()
