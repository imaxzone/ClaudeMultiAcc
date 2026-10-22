#!/bin/bash
# Builds a release into dist/: ClaudeMultiAcc.app, ClaudeMultiAcc-<version>.zip and .dmg, each with a .sha256 file.
# Usage: scripts/release.sh [--sign <sha1|->] [--tag <vX.Y.Z>]
#   --sign  signing identity for the app (default "-": ad hoc; releases are not notarized)
#   --tag   fail unless the tag is v<VERSION> (the release workflow passes the pushed tag)
#   The version comes from VERSION and lands in CFBundleShortVersionString, which the in-app update check compares
#   with the latest GitHub release tag. Nothing is uploaded: the release workflow (or you) attaches dist/* to a release.
set -euo pipefail

usage() {
  echo "Usage: $0 [--sign <sha1|->] [--tag <vX.Y.Z>]" >&2
  exit 64
}

SIGN="-"
TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) [[ $# -ge 2 ]] || usage; SIGN="$2"; shift 2 ;;
    --tag) [[ $# -ge 2 ]] || usage; TAG="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ -n "$TAG" && "$TAG" != "v$VERSION" ]]; then
  echo "Tag $TAG does not match VERSION ($VERSION): bump VERSION or tag v$VERSION." >&2
  exit 65
fi

DIST="$ROOT/dist"
APP="$DIST/ClaudeMultiAcc.app"
NAME="ClaudeMultiAcc-$VERSION"
ZIP="$DIST/$NAME.zip"
DMG="$DIST/$NAME.dmg"

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "release: $*" >&2; exit 1; }

# 1. Build and bundle. bundle-app.sh builds each product with its own `swift build -c release --product X`
#    (one --product per command: with several, this toolchain builds only the last one) and signs the app.
step "Build and bundle $VERSION (sign: $SIGN)"
rm -f "$ZIP" "$ZIP.sha256" "$DMG" "$DMG.sha256"
scripts/bundle-app.sh --sign "$SIGN" >/dev/null

# 2. Check the bundle before packaging it.
step "Verify the app"
codesign --verify --deep --strict --verbose=2 "$APP"
INFO="$APP/Contents/Info.plist"
SHORT="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO")"
[[ "$SHORT" == "$VERSION" ]] || fail "CFBundleShortVersionString is '$SHORT', VERSION is '$VERSION'"
for binary in MacOS/ClaudeMultiAcc Helpers/cmacc Helpers/CloneLauncher; do
  [[ -x "$APP/Contents/$binary" ]] || fail "missing $binary"
  lipo -archs "$APP/Contents/$binary" | grep -qw arm64 || fail "$binary is not built for arm64"
done
for bundle in Support InstanceBuilder UI; do
  for language in en ru; do
    strings="$APP/Contents/Resources/ClaudeMultiAcc_$bundle.bundle/Contents/Resources/$language.lproj/Localizable.strings"
    [[ -f "$strings" ]] || fail "missing $strings"
  done
done
"$APP/Contents/Helpers/cmacc" ui strings >/dev/null || fail "the bundled cmacc does not find its string tables"
echo "version $SHORT, build $(plutil -extract CFBundleVersion raw -o - "$INFO")"

# 3. Package: a zip (ditto keeps the signature and symlinks intact) and a dmg with an Applications link.
step "Package"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/cmacc-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/ClaudeMultiAcc.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "ClaudeMultiAcc $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null 2>&1 || fail "hdiutil verify failed for $DMG"

# 4. Checksums: `shasum -a 256 -c <file>.sha256` run in dist/ checks a download.
step "Checksums"
for file in "$ZIP" "$DMG"; do
  (cd "$DIST" && shasum -a 256 "$(basename "$file")" > "$(basename "$file").sha256")
  cat "$file.sha256"
done

step "Done"
for file in "$ZIP" "$DMG"; do
  printf '%8s  %s\n' "$(du -h "$file" | cut -f1)" "${file#"$ROOT"/}"
done
