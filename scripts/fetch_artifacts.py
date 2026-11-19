"""Download this project's CI artifact and safely retain build output locally."""
import argparse
import io
import json
from pathlib import Path
import urllib.request
import zipfile
from github_ci import credential, NoAuthRedirect

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run_id", type=int)
    parser.add_argument("--artifact", default="Iny-iOS-build")
    args = parser.parse_args()
    token = credential()
    opener = urllib.request.build_opener(NoAuthRedirect())

    def get(url):
        request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json"})
        with opener.open(request, timeout=60) as response:
            return response.read()

    listing = json.loads(get(f"https://api.github.com/repos/hysgit/iny/actions/runs/{args.run_id}/artifacts"))
    selected = next(item for item in listing["artifacts"] if item["name"] == args.artifact and not item["expired"])
    data = get(selected["archive_download_url"])
    folder = ROOT / "analysis/cloud" / str(args.run_id) / "artifacts"
    folder.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for member in archive.infolist():
            destination = (folder / member.filename).resolve()
            if not destination.is_relative_to(folder.resolve()) or ((member.external_attr >> 16) & 0o170000) == 0o120000:
                raise RuntimeError("Unsafe artifact archive member")
        archive.extractall(folder)
    print(json.dumps({"run": args.run_id, "artifact": selected["name"], "bytes": len(data), "directory": str(folder)}, indent=2))


if __name__ == "__main__":
    main()
