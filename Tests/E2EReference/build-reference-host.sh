#!/bin/bash
# Builds the SwiftUI reference host as a minimal .app bundle — no Xcode project
# required, so it compiles in seconds with just the toolchain.
#
# Usage: build-reference-host.sh <macos|ios> <output-dir>
#
# Produces <output-dir>/E2EReference.app. Launch it with
#   -E2EExample <name> -E2ETitle <window title>
# via `open -W --args` (macOS) or `simctl launch` (iOS).

set -euo pipefail

PLATFORM="${1:?usage: build-reference-host.sh <macos|ios> <output-dir>}"
OUT_DIR="${2:?usage: build-reference-host.sh <macos|ios> <output-dir>}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$OUT_DIR/E2EReference.app"

case "$PLATFORM" in
  macos)
    BIN_DIR="$APP/Contents/MacOS"
    PLIST="$APP/Contents/Info.plist"
    PLATFORMS=("MacOSX")
    MIN_KEY="LSMinimumSystemVersion"
    MIN_VERSION="$(sw_vers -productVersion)"
    ;;
  ios)
    BIN_DIR="$APP"
    PLIST="$APP/Info.plist"
    PLATFORMS=("iPhoneSimulator")
    MIN_KEY="MinimumOSVersion"
    MIN_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-platform-version)"
    ;;
  *)
    echo "unknown platform: $PLATFORM" >&2
    exit 1
    ;;
esac

rm -rf "$APP"
mkdir -p "$BIN_DIR"

SOURCES=()
while IFS= read -r file; do
  SOURCES+=("$file")
done < <(find "$ROOT/Sources" -name '*.swift' | sort)

if [[ "$PLATFORM" == "ios" ]]; then
  swiftc -O -o "$BIN_DIR/E2EReference" ${SOURCES[@]+"${SOURCES[@]}"} \
    -target "arm64-apple-ios${MIN_VERSION}-simulator" \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
else
  swiftc -O -o "$BIN_DIR/E2EReference" ${SOURCES[@]+"${SOURCES[@]}"}
fi

mkdir -p "$(dirname "$PLIST")"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict></dict></plist>\n' > "$PLIST"
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleExecutable string E2EReference" \
  -c "Add :CFBundleIdentifier string dev.waterui.E2EReference" \
  -c "Add :CFBundleName string E2EReference" \
  -c "Add :CFBundlePackageType string APPL" \
  -c "Add :CFBundleShortVersionString string 1.0" \
  -c "Add :CFBundleVersion string 1" \
  -c "Add :$MIN_KEY string $MIN_VERSION" \
  -c "Add :CFBundleSupportedPlatforms array" \
  -c "Add :CFBundleSupportedPlatforms:0 string ${PLATFORMS[0]}" \
  "$PLIST"

# Ad-hoc sign so the arm64 binary is launchable on Apple Silicon.
codesign --force --sign - "$APP" >/dev/null 2>&1 || codesign --force --sign - "$BIN_DIR/E2EReference"

echo "Built $APP"
