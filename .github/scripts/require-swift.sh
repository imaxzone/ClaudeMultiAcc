#!/bin/bash
# Prints the toolchain and fails unless the active Swift is at least the given version (default 6.4).
# When the default toolchain is older, selects the newest /Applications/Xcode_27*.app first, if the image has one.
# Usage: .github/scripts/require-swift.sh [major.minor]
set -euo pipefail

MIN="${1:-6.4}"

swift_version() {
  swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1
}

older_than_min() { # version
  local major minor min_major min_minor
  IFS=. read -r major minor <<< "$1"
  IFS=. read -r min_major min_minor <<< "$MIN"
  (( major < min_major || (major == min_major && minor < min_minor) ))
}

VERSION="$(swift_version)"
if [[ -z "$VERSION" ]] || older_than_min "$VERSION"; then
  XCODE="$(ls -d /Applications/Xcode_27*.app 2>/dev/null | sort | tail -1 || true)"
  if [[ -n "$XCODE" ]]; then
    echo "Swift ${VERSION:-unknown} is older than $MIN; selecting $XCODE"
    sudo xcode-select -s "$XCODE"
    VERSION="$(swift_version)"
  fi
fi

sw_vers
xcodebuild -version || true
swift --version
if [[ -z "$VERSION" ]] || older_than_min "$VERSION"; then
  echo "::error::Swift ${VERSION:-unknown} is too old: this package needs Swift $MIN or newer (Xcode 27). Use a runner image with Xcode 27 (runs-on: xcode-27)."
  exit 1
fi
echo "Swift $VERSION OK (needs $MIN+)"
