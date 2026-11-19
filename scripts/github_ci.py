"""Follow the user's hysgit/iny macOS build. Never writes tokens."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request
import zipfile
import io

ROOT = Path(__file__).resolve().parents[1]


class NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        redirected = super().redirect_request(request, fp, code, message, headers, new_url)
        if redirected:
            redirected.remove_header("Authorization")
        return redirected


def credential(interactive=False):
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        return token
    helper = Path("C:/Program Files/Git/mingw64/bin/git-credential-manager-core.exe")
    env = dict(os.environ, GCM_INTERACTIVE="Auto" if interactive else "Never", GIT_TERMINAL_PROMPT="0")
    result = subprocess.run([str(helper), "get"], input="protocol=https\nhost=github.com\n\n", capture_output=True, text=True, env=env, timeout=240 if interactive else 15)
    values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    if not values.get("password"):
        raise RuntimeError("GitHub login is required. Complete the credential-manager account selection, then retry.")
    return values["password"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--interactive", action="store_true")
    parser.add_argument("--watch-only", action="store_true")
    args = parser.parse_args()
    token = credential(args.interactive)
    opener = urllib.request.build_opener(NoAuthRedirect())

    def api(path, method="GET", payload=None, raw=False):
        request = urllib.request.Request("https://api.github.com" + path, method=method,
            data=json.dumps(payload).encode() if payload is not None else None,
            headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json", "Content-Type": "application/json"})
        with opener.open(request, timeout=30) as response:
            content = response.read()
        return content if raw else (json.loads(content) if content else None)

    user = api("/user")["login"]
    if user != "hysgit":
        raise RuntimeError("Expected the existing hysgit account; no repository was changed")
    repo_path = "/repos/hysgit/iny"
    repository = api(repo_path)
    print("User-specified repository: " + repository["html_url"], flush=True)
    if not args.watch_only:
        existing = subprocess.run(["git", "remote", "get-url", "origin"], cwd=ROOT, capture_output=True, text=True)
        if existing.returncode:
            subprocess.run(["git", "remote", "add", "origin", repository["ssh_url"]], cwd=ROOT, check=True)
        elif existing.stdout.strip() != repository["ssh_url"]:
            raise RuntimeError("Origin differs from the Iny repository; refusing to replace it")
        subprocess.run(["git", "push", "-u", "origin", "master"], cwd=ROOT, check=True, env=dict(os.environ, GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=20"))
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    previous = None
    for attempt in range(90):
        runs = api(repo_path + "/actions/runs?branch=master&per_page=10")["workflow_runs"]
        matches = [run for run in runs if run["head_sha"] == sha]
        if not matches:
            if attempt == 2:
                api(repo_path + "/actions/workflows/ios.yml/dispatches", "POST", {"ref": "master"})
            time.sleep(20)
            continue
        run = matches[0]
        status = (run["status"], run["conclusion"])
        if status != previous:
            print("Build: " + run["html_url"] + " " + str(status), flush=True)
            previous = status
        folder = ROOT / "analysis/cloud" / str(run["id"])
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "status.json").write_text(json.dumps({k: run[k] for k in ["id", "html_url", "head_sha", "status", "conclusion"]}, indent=2), encoding="utf-8")
        if run["status"] == "completed":
            data = api(repo_path + f"/actions/runs/{run['id']}/logs", raw=True)
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                for member in archive.namelist():
                    if member.endswith(".txt"):
                        filename = member.replace("/", "__").replace("\\", "__")
                        content = archive.read(member)
                        (folder / filename).write_bytes(content)
                        lines = content.decode("utf-8", errors="replace").splitlines()
                        failures = [line for line in lines if any(word in line.lower() for word in ["error:", "failed", "executed "])]
                        if failures:
                            print("\n".join(failures[-35:]), flush=True)
            raise SystemExit(0 if run["conclusion"] == "success" else 1)
        time.sleep(30)
    raise SystemExit("Cloud build did not finish within the observation period")


if __name__ == "__main__":
    main()
