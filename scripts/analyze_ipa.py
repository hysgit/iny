"""Read-only IPA inventory and recovery evidence; does not execute the app."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import zipfile

FEATURE_WORDS = {
    "播放与队列": ["playback", "play", "queue", "chapter", "speed", "resume"],
    "字幕": ["subtitle", "caption", "字体"],
    "媒体库与元数据": ["library", "metadata", "poster", "collection", "rating"],
    "网络共享": ["webdav", "smb", "nfs", "ftp", "sftp", "shareprotocol"],
    "媒体服务器": ["emby", "jellyfin", "plex"],
    "云盘": ["dropbox", "onedrive", "google drive", "aliyun", "阿里云", "cloudstream"],
    "同步与账号": ["trakt", "icloud", "cloudsync"],
    "投屏与外设": ["airplay", "googlecast", "google cast", "hdmi", "externaldisplay"],
    "高级音视频": ["dolby", "dts", "hdr", "tonemapping", "vision"],
    "隐私与限制": ["passcode", "touchid", "faceid", "restriction"],
    "下载与传输": ["download", "upload", "transfer"],
}


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8", newline="\n")


def analyze(path, output):
    output.mkdir(parents=True, exist_ok=True)
    with path.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        main = []
        for name in names:
            if name.startswith("Payload/") and name.count("/") == 2 and name.endswith("/Info.plist"):
                info = plistlib.loads(archive.read(name))
                if "CFBundleExecutable" in info:
                    main.append((name, info))
        if len(main) != 1:
            raise ValueError("Expected exactly one main application")
        name, info = main[0]
        root = name.rsplit("/", 1)[0] + "/"
        summary = {key: info.get(key) for key in ["CFBundleDisplayName", "CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion", "NSBonjourServices", "CFBundleURLTypes"]}
        summary["archiveSHA256"] = digest
        summary["archiveBytes"] = path.stat().st_size
        summary["memberCount"] = len(names)
        summary["extensions"] = dict(collections.Counter(Path(member).suffix for member in names))
        executable = archive.read(root + info["CFBundleExecutable"])
        if executable[:4] != b"\xcf\xfa\xed\xfe":
            raise ValueError("This analyzer expects a thin little-endian 64-bit Mach-O")
        header = struct.unpack_from("<8I", executable)
        offset = 32
        encryption = []
        for _ in range(header[4]):
            if offset + 8 > len(executable):
                raise ValueError("Truncated Mach-O load commands")
            command, size = struct.unpack_from("<II", executable, offset)
            if size < 8 or offset + size > len(executable):
                raise ValueError("Invalid Mach-O load command")
            if command in (0x21, 0x2C):
                cryptoff, cryptsize, cryptid = struct.unpack_from("<3I", executable, offset + 8)
                encryption.append({"cmd": hex(command), "cryptoff": cryptoff, "cryptsize": cryptsize, "cryptid": cryptid})
            offset += size
        write_json(output / "package-info.json", summary)
        write_json(output / "encryption.json", encryption)
        (output / "inventory.txt").write_text("\n".join(names), encoding="utf-8", newline="\n")
        localizations = {}
        for language in ["zh-Hans", "en"]:
            filename = root + language + ".lproj/Localizable.strings"
            localizations[language] = plistlib.loads(archive.read(filename))
            write_json(output / (language + "-Localizable.strings.json"), localizations[language])
        catalog = {}
        for category, words in FEATURE_WORDS.items():
            catalog[category] = [{"key": key, "text": value} for key, value in localizations["zh-Hans"].items() if any(word in (key + " " + value).lower() for word in words)]
        write_json(output / "feature-catalog.json", catalog)
        frameworks = [member for member in names if member.startswith(root + "Frameworks/") and member.endswith(".framework/Info.plist")]
        write_json(output / "frameworks.json", [{"name": member.split("/")[-2], "version": plistlib.loads(archive.read(member)).get("CFBundleShortVersionString")} for member in frameworks])
        print(json.dumps({"sha256": digest, "members": len(names), "encryption": encryption,
                          "localizationKeys": {language: len(values) for language, values in localizations.items()},
                          "frameworks": len(frameworks)}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--output", type=Path, default=Path("analysis"))
    args = parser.parse_args()
    analyze(args.ipa, args.output)
