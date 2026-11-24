#!/usr/bin/env bash
# Build Quadrat into /tmp and install ~/Applications/Quadrat.app.
# Re-signs with a local Apple Development identity when one exists, otherwise ad hoc.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required (brew install xcodegen)" >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required" >&2
  exit 1
fi

xcodegen generate
DERIVED="/tmp/quadrat-derived"
rm -rf "$DERIVED"
xcodebuild \
  -project Quadrat.xcodeproj \
  -scheme Quadrat \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_HARDENED_RUNTIME=YES \
  build

APP_SRC="$DERIVED/Build/Products/Release/Quadrat.app"
if [[ ! -d "$APP_SRC" ]]; then
  echo "build did not produce $APP_SRC" >&2
  exit 1
fi

DEST="${HOME}/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/Quadrat.app"
cp -R "$APP_SRC" "$DEST/Quadrat.app"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1 || true)"
if [[ -n "${IDENTITY}" ]]; then
  echo "Signing with ${IDENTITY}"
  codesign --force --deep --options runtime --sign "$IDENTITY" --entitlements App/Quadrat.entitlements "$DEST/Quadrat.app"
else
  echo "No Apple Development identity found; ad-hoc signing"
  codesign --force --deep --options runtime --sign - --entitlements App/Quadrat.entitlements "$DEST/Quadrat.app"
fi

echo "Installed $DEST/Quadrat.app"
