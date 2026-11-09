#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
framework="${PYTHON_FRAMEWORK:-/Library/Frameworks/Python.framework}"
out="${OUTPUT_DIR:-$root/build}"
app="$out/IPCC提取工具.app"
if [[ ! -x "$framework/Versions/3.13/bin/python3.13" ]]; then
  echo 'Python 3.13 framework not found. Set PYTHON_FRAMEWORK to its Python.framework path.' >&2
  exit 1
fi
if [[ -e "$app" ]]; then
  echo "Output already exists: $app. Choose an empty OUTPUT_DIR." >&2
  exit 1
fi
/usr/bin/lipo -verify_arch arm64 "$framework/Versions/3.13/Python"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$root/Info.plist" "$app/Contents/Info.plist"
cp "$root/AppIcon.icns" "$app/Contents/Resources/AppIcon-1.5.icns"
cp "$root/devices.json" "$app/Contents/Resources/devices.json"
cp "$root/engine.py" "$app/Contents/Resources/engine.py"
mkdir -p "$app/Contents/Resources/en.lproj" "$app/Contents/Resources/zh-Hans.lproj"
cp "$root/InfoPlist.en.strings" "$app/Contents/Resources/en.lproj/InfoPlist.strings"
cp "$root/InfoPlist.zh-Hans.strings" "$app/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
/usr/bin/ditto "$framework" "$app/Contents/Frameworks/Python.framework"
xcrun swiftc -O -target arm64-apple-macosx14.0 "$root/App.swift" "$root/Language.swift" -o "$app/Contents/MacOS/IPCCExtractor"
xcrun swiftc -O -target arm64-apple-macosx14.0 "$root/AEAKey.swift" -o "$app/Contents/Resources/aea-key"
/usr/bin/codesign --force --deep --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
touch "$app"
printf 'Built: %s\n' "$app"
