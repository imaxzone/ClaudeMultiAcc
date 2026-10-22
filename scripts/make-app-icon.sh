#!/bin/bash
# Compiles the app icon from its Icon Composer source, assets/AppIcon.icon (Liquid Glass, macOS 26+), into
# assets/AppIcon/Assets.car (the icon, named AppIcon) and assets/AppIcon/AppIcon.icns (the flat fallback).
# Needs Xcode 26+ (actool is not in the Command Line Tools). The compiled files are committed, so building the app
# (scripts/bundle-app.sh, CI) never needs Xcode; run this after editing the icon in Icon Composer.
# Usage: scripts/make-app-icon.sh
set -euo pipefail
[[ $# -eq 0 ]] || { echo "Usage: $0" >&2; exit 64; }
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SOURCE="$ROOT/assets/AppIcon.icon"
OUT="$ROOT/assets/AppIcon"
ACTOOL="$(xcrun --find actool 2>/dev/null)" || { echo "actool not found: install Xcode 26+ and run xcode-select -s" >&2; exit 69; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

"$ACTOOL" "$SOURCE" --compile "$WORK" --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$WORK/partial.plist" --output-format human-readable-text >"$WORK/actool.log" 2>&1 \
  || { cat "$WORK/actool.log" >&2; exit 1; }
for file in Assets.car AppIcon.icns; do
  [[ -s "$WORK/$file" ]] || { echo "actool produced no $file" >&2; cat "$WORK/actool.log" >&2; exit 1; }
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$WORK/partial.plist")" == "AppIcon" ]] \
  || { echo "actool did not name the icon AppIcon" >&2; exit 1; }

mkdir -p "$OUT"
cp "$WORK/Assets.car" "$WORK/AppIcon.icns" "$OUT/"
echo "$OUT/Assets.car"
echo "$OUT/AppIcon.icns"
