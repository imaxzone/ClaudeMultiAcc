#!/bin/bash
# Builds ClaudeMultiAcc.app into dist/.
# Usage: scripts/bundle-app.sh [--release] [--without-url-scheme] [--sign <sha1|->]
#   The app declares the claude URL type by default (Task 7 link router); declaring it never claims the scheme.
#   --without-url-scheme  omit CFBundleURLTypes (--with-url-scheme is accepted as a no-op for compatibility)
#   CFBundleShortVersionString comes from VERSION. CFBundleVersion is $BUILD_NUMBER when set, else the commit count of
#   this checkout, else 0 (a source archive without git: 0 never outranks a real build in LaunchServices).
set -euo pipefail

usage() {
  echo "Usage: $0 [--release] [--without-url-scheme] [--sign <sha1|->]" >&2
  exit 64
}

WITH_URL_SCHEME=1
SIGN="-"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) shift ;; # default and only configuration
    --with-url-scheme) WITH_URL_SCHEME=1; shift ;;
    --without-url-scheme) WITH_URL_SCHEME=0; shift ;;
    --sign) [[ $# -ge 2 ]] || usage; SIGN="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

BUNDLE_ID="com.imaxzone.ClaudeMultiAcc"
APP="$ROOT/dist/ClaudeMultiAcc.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "VERSION must look like 1.2.3, got '$VERSION'" >&2; exit 65; }

# Commit count only when ROOT is itself the top of a git checkout (not a source archive unpacked inside another repo).
build_number() {
  local top
  top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$top" && "$(cd "$top" && pwd -P)" == "$ROOT" ]]; then
    git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0
  else
    echo 0
  fi
}
BUILD_NUMBER="${BUILD_NUMBER:-$(build_number)}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "BUILD_NUMBER must be a number, got '$BUILD_NUMBER'" >&2; exit 65; }

# 1. Build.
for product in ClaudeMultiAcc cmacc CloneLauncher; do
  swift build -c release --product "$product"
done
BIN="$(swift build -c release --show-bin-path)"

# 2. Assemble (from scratch, so reruns are idempotent).
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/ClaudeMultiAcc" "$APP/Contents/MacOS/ClaudeMultiAcc"
cp "$BIN/cmacc" "$APP/Contents/Helpers/cmacc"
cp "$BIN/CloneLauncher" "$APP/Contents/Helpers/CloneLauncher"

# 3. Info.plist.
URL_TYPES=""
if [[ $WITH_URL_SCHEME -eq 1 ]]; then
  URL_TYPES="  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>ClaudeMultiAcc link router</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>claude</string>
      </array>
    </dict>
  </array>
"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>ClaudeMultiAcc</string>
  <key>CFBundleDisplayName</key>
  <string>ClaudeMultiAcc</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>ru</string>
  </array>
  <key>CFBundleExecutable</key>
  <string>ClaudeMultiAcc</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
${URL_TYPES}</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# --- Resources (later tasks append resource copies here) ---
# The SwiftPM resource bundles with the English and Russian string tables. Every executable looks for them in
# Contents/Resources (Support's ResourceBundles: Bundle.main.resourceURL for the app, ../Resources from
# Contents/Helpers for cmacc). CloneLauncher shows no text and needs none.
RESOURCE_BUNDLES=(ClaudeMultiAcc_Support ClaudeMultiAcc_InstanceBuilder ClaudeMultiAcc_UI)
for bundle in "${RESOURCE_BUNDLES[@]}"; do
  [[ -d "$BIN/$bundle.bundle" ]] || { echo "missing $BIN/$bundle.bundle" >&2; exit 1; }
  cp -R "$BIN/$bundle.bundle" "$APP/Contents/Resources/$bundle.bundle"
done
# Help the installed app can open (P6): the step-6 RUNBOOK. scripts/signing-setup.sh is NOT shipped: the app creates
# its signing identity itself in its own keychain (SigningIdentityProvisioner); the script, which imports into the
# login keychain, stays a developer tool in the repo.
HELP="$APP/Contents/Resources/Help"
mkdir -p "$HELP"
cp docs/RUNBOOK-step6.md "$HELP/RUNBOOK-step6.md"
# ------------------------------------------------------------

# 4. Sign: helpers and resource bundles first, then the app. Never --deep.
for helper in cmacc CloneLauncher; do
  codesign --force --timestamp=none --sign "$SIGN" --options runtime "$APP/Contents/Helpers/$helper"
done
for bundle in "${RESOURCE_BUNDLES[@]}"; do
  codesign --force --timestamp=none --sign "$SIGN" "$APP/Contents/Resources/$bundle.bundle"
done
codesign --force --timestamp=none --sign "$SIGN" --options runtime "$APP"

# 5. Report.
echo "$APP"
