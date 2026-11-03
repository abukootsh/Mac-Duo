#!/usr/bin/env bash
#
# Builds "build/Mac Duo.app" from the Swift package.
#
#   ./build.sh              build and sign (ad-hoc)
#   ./build.sh --run        build, sign, and relaunch
#   ./build.sh --universal  build for Apple Silicon and Intel
#
# Set SIGN_IDENTITY to sign with your own certificate. With ad-hoc signing,
# macOS may ask for Screen Recording permission again after each rebuild.

set -euo pipefail
cd "$(dirname "$0")"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/Mac Duo.app"
ARGS=(-c release)
RUN=false
for arg in "$@"; do
  case "$arg" in
    --universal) ARGS+=(--arch arm64 --arch x86_64) ;;
    --run) RUN=true ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

swift build "${ARGS[@]}" --product MacDuo
swift build "${ARGS[@]}" --product lidprobe
BIN="$(swift build "${ARGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacDuo" "$APP/Contents/MacOS/MacDuo"
cp -R "$BIN/MacDuo_MacDuo.bundle" "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp LICENSE NOTICE "$APP/Contents/Resources/"
cp "$BIN/lidprobe" build/lidprobe

if [[ "$SIGN_IDENTITY" == - ]]; then TS=--timestamp=none; else TS=--timestamp; fi
codesign --force --options runtime "$TS" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "built $APP"

if "$RUN"; then
  pkill -x MacDuo 2>/dev/null || true
  sleep 0.5
  open "$APP"
fi
