#!/usr/bin/env bash
# Builds AlcoveInspired.app (Release) and optionally installs it.
#
#   Scripts/build-app.sh                 # xcodebuild (needs Xcode 16+)
#   Scripts/build-app.sh --spm           # SwiftPM (Command Line Tools are enough)
#   Scripts/build-app.sh --install       # ...and copy to /Applications
#   Scripts/build-app.sh --output DIR    # output directory (default: build/)
#
# The result is ad-hoc signed ("Sign to Run Locally"). macOS ties privacy
# permissions (Accessibility, Automation) to the signature, so after a rebuild
# you may need to grant them again. Sign with your Apple Development identity
# (set DEVELOPMENT_TEAM in Xcode) to keep them across builds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="xcode"
INSTALL=0
OUT="$ROOT/build"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spm) MODE="spm" ;;
    --xcode) MODE="xcode" ;;
    --install) INSTALL=1 ;;
    --output) OUT="$(mkdir -p "$2" && cd "$2" && pwd)"; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

APP_NAME="AlcoveInspired"
APP="$OUT/$APP_NAME.app"
mkdir -p "$OUT"

setting() {
  # Reads a build setting from the generated Xcode project.
  grep -m1 "$1 = " "$ROOT/$APP_NAME.xcodeproj/project.pbxproj" | sed -E 's/.*= "?([^";]*)"?;/\1/'
}

if [[ "$MODE" == "xcode" ]]; then
  if ! xcodebuild -version >/dev/null 2>&1; then
    echo "xcodebuild is not available (install Xcode 16+), falling back to --spm" >&2
    MODE="spm"
  fi
fi

if [[ "$MODE" == "xcode" ]]; then
  xcodebuild \
    -project "$ROOT/$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$OUT/DerivedData" \
    CODE_SIGN_IDENTITY=- \
    build
  rm -rf "$APP"
  ditto "$OUT/DerivedData/Build/Products/Release/$APP_NAME.app" "$APP"
else
  swift build -c release --package-path "$ROOT"
  BIN_DIR="$(swift build -c release --package-path "$ROOT" --show-bin-path)"

  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

  VERSION="$(setting MARKETING_VERSION)"
  BUILD="$(setting CURRENT_PROJECT_VERSION)"
  BUNDLE_ID="$(setting PRODUCT_BUNDLE_IDENTIFIER)"
  TARGET="$(setting MACOSX_DEPLOYMENT_TARGET)"
  sed \
    -e "s/\$(DEVELOPMENT_LANGUAGE)/en/" \
    -e "s/\$(EXECUTABLE_NAME)/$APP_NAME/" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" \
    -e "s/\$(PRODUCT_NAME)/$APP_NAME/" \
    -e "s/\$(PRODUCT_BUNDLE_PACKAGE_TYPE)/APPL/" \
    -e "s/\$(MARKETING_VERSION)/$VERSION/" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD/" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$TARGET/" \
    "$ROOT/Config/Info.plist" > "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"

  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  cp "$ROOT/$APP_NAME/Resources/Assets.xcassets/AppIcon.appiconset/"icon_*.png "$ICONSET/"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

  for lproj in "$ROOT/$APP_NAME/Resources/"*.lproj; do
    [[ -d "$lproj" ]] && cp -R "$lproj" "$APP/Contents/Resources/"
  done

  # NowPlayingHelper: the system-wide "Now Playing" helper, loaded at runtime
  # by /usr/bin/perl (see MediaRemoteBridge). Compiled for the host arch, to
  # match the SwiftPM-built executable, and signed before the app so the
  # bundle's signature stays valid.
  mkdir -p "$APP/Contents/Frameworks"
  xcrun clang \
    -arch "$(uname -m)" \
    -mmacosx-version-min="$TARGET" \
    -fobjc-arc \
    -dynamiclib \
    -install_name "@rpath/libNowPlayingHelper.dylib" \
    -framework AppKit -framework Foundation \
    -o "$APP/Contents/Frameworks/libNowPlayingHelper.dylib" \
    "$ROOT/NowPlayingHelper/NowPlayingHelper.m"
  codesign --force --sign - "$APP/Contents/Frameworks/libNowPlayingHelper.dylib"

  codesign --force --sign - \
    --entitlements "$ROOT/Config/$APP_NAME.entitlements" \
    --options runtime \
    "$APP"
fi

codesign --verify --strict "$APP"
echo "Built $APP"

if [[ "$INSTALL" == "1" ]]; then
  if pgrep -x "$APP_NAME" >/dev/null; then
    osascript -e "tell application id \"$(defaults read "$APP/Contents/Info" CFBundleIdentifier)\" to quit" || true
    sleep 1
    pkill -x "$APP_NAME" || true
  fi
  rm -rf "/Applications/$APP_NAME.app"
  ditto "$APP" "/Applications/$APP_NAME.app"
  echo "Installed /Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
fi
