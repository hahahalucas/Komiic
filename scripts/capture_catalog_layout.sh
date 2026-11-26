#!/bin/bash
# Capture real simulator renders with a catalog that does not depend on live data.
set -euo pipefail

OUTPUT_DIR="$1"
mkdir -p "$OUTPUT_DIR/screenshots"
xcrun simctl list devices available --json > "$OUTPUT_DIR/devices.json"
python3 - "$OUTPUT_DIR/devices.json" > "$OUTPUT_DIR/simulator-plan.txt" <<'PY'
import json
import re
import sys

with open(sys.argv[1]) as source:
    devices = json.load(source)["devices"]
families = ("iPhone", "iPad")
for runtime in sorted(devices, key=lambda name: tuple(map(int, re.findall(r"\d+", name))), reverse=True):
    match = re.search(r"\.iOS-(\d+)", runtime)
    if not match or int(match[1]) < 26:
        continue
    plan = [
        next((device["udid"] for device in devices[runtime] if device["name"].startswith(family)), None)
        for family in families
    ]
    if all(plan):
        for family, udid in zip(families, plan):
            print(family, udid)
        break
else:
    raise SystemExit("The layout check needs iPhone and iPad simulators on iOS 26 or later.")
PY

xcodebuild -quiet -project Komiic.xcodeproj -scheme Komiic -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$OUTPUT_DIR/DerivedData" CODE_SIGNING_ALLOWED=NO build
APP="$OUTPUT_DIR/DerivedData/Build/Products/Debug-iphonesimulator/Komiic.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"

while read -r device_kind device_id; do
  xcrun simctl boot "$device_id" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$device_id" -b
  xcrun simctl ui "$device_id" appearance light
  xcrun simctl install "$device_id" "$APP"
  DATA_DIR="$(xcrun simctl get_app_container "$device_id" "$BUNDLE_ID" data)"

  python3 - "$DATA_DIR" <<'PY'
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib

directory = Path(sys.argv[1]) / "Library/Application Support/Komiic/ContentSnapshots"
directory.mkdir(parents=True, exist_ok=True)

def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

width, height = 120, 168
colors = ((225, 87, 110), (13, 126, 162), (249, 167, 87), (50, 160, 120), (122, 91, 192), (52, 124, 219))
cover_urls = []
for index, color in enumerate(colors):
    rows = []
    for y in range(height):
        row = bytearray((0,))
        for x in range(width):
            light = 48 if ((x + y * 2) // 26) % 2 else 0
            row.extend(min(255, channel + light) for channel in color)
        rows.append(row)
    cover = directory / f"fixture-cover-{index}.png"
    cover.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(b"".join(rows)))
        + png_chunk(b"IEND", b"")
    )
    cover_urls.append(cover.as_uri())
comics = [
    {"id": f"layout-{index}", "title": f"示例漫画 {index + 1:02}", "imageUrl": cover_urls[index % len(cover_urls)]}
    for index in range(30)
]
key = hashlib.sha256(b"catalog:REGULAR:updated:guest:-1").hexdigest()
(directory / f"{key}.json").write_text(json.dumps({"comics": comics, "offset": len(comics), "hasMore": False}))
PY

  xcrun simctl launch "$device_id" "$BUNDLE_ID"
  sleep 5
  xcrun simctl io "$device_id" screenshot "$OUTPUT_DIR/screenshots/Komiic-$device_kind.png"
  xcrun simctl terminate "$device_id" "$BUNDLE_ID"
  xcrun simctl shutdown "$device_id"
done < "$OUTPUT_DIR/simulator-plan.txt"
