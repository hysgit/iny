"""Render the Iny icon from simple geometric shapes using only the standard library."""
from pathlib import Path
import binascii
import json
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF)


def color(x, y):
    # 白色胶片边与橙色播放符号，图标保持不透明，让 iOS 应用圆角。
    if 205 <= x <= 302 and 360 <= y <= 765:
        return (243, 247, 253)
    if (x - 253.5) ** 2 + (y - 249) ** 2 <= 53 ** 2:
        return (243, 247, 253)
    if 420 <= x <= 820 and 295 + 0.575 * (x - 420) <= y <= 755 - 0.575 * (x - 420):
        return (255, 159, 34)
    return (13, 21, 34)


def generate():
    size = 1024
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        for x in range(size):
            samples = [color(x + dx, y + dy) for dx, dy in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]]
            raw.extend(sum(c[channel] for c in samples) // 4 for channel in range(3))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    assets = ROOT / "App/Assets.xcassets"
    icon = assets / "AppIcon.appiconset"
    icon.mkdir(parents=True, exist_ok=True)
    (icon / "Iny.png").write_bytes(png)
    (assets / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2), encoding="utf-8")
    contents = {"images": [{"filename": "Iny.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}
    (icon / "Contents.json").write_text(json.dumps(contents, indent=2), encoding="utf-8")
    print("Generated opaque RGB Iny icon, 1024 x 1024")


if __name__ == "__main__":
    generate()
