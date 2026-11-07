#!/bin/bash
# Builds the Mac app in Release and packages it as dist/LiveTranslate-<version>.dmg.
#
# The Xcode build copies runtime/mlx, a uv virtualenv whose python is a symlink
# to this machine's interpreter. For a DMG that runs on another Mac, the bundle
# gets a self-contained CPython with the MLX packages copied into it instead.
# Model weights are not in the DMG; the app downloads them from Hugging Face.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-0.2.0}
BUILD=${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}
DERIVED="$ROOT/DerivedData-Release"
OUT="$ROOT/dist"
APP="$DERIVED/Build/Products/Release/LiveTranslate.app"

echo "==> Release build $VERSION ($BUILD)"
xcodebuild -project "$ROOT/LiveTranslate.xcodeproj" -scheme LiveTranslate -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

echo "==> Portable MLX runtime"
VENV="$ROOT/runtime/mlx"
BASE=$(dirname "$(dirname "$(readlink -f "$VENV/bin/python")")")
PYVER=$(basename "$(ls -d "$VENV"/lib/python3.*)")
RUNTIME="$APP/Contents/Resources/mlx-runtime"
rm -rf "$RUNTIME"
mkdir -p "$RUNTIME"
rsync -a --exclude '__pycache__' --exclude 'test/' --exclude 'idlelib/' --exclude 'tkinter/' "$BASE/" "$RUNTIME/"
rsync -a --exclude '__pycache__' "$VENV/lib/$PYVER/site-packages/" "$RUNTIME/lib/$PYVER/site-packages/"
"$RUNTIME/bin/python3" -I -c "import mlx_lm, mlx.core; print('mlx', mlx.core.__version__)"

# The menu bar, About and Quit use CFBundleName, which Xcode sets to the product name
# "LiveTranslate". People see "Live Translate"; the executable keeps its name for `--mcp`.
plutil -replace CFBundleName -string "Live Translate" "$APP/Contents/Info.plist"

# Gatekeeper accepts a downloaded app only when it is signed with a Developer ID
# Application certificate and notarized. Without one, the DMG is ad-hoc signed and
# macOS warns that it may be dangerous.
# Published by Nimbl3 Ltd. (team 4TWS7E2EPE): its Developer ID first, then any other.
TEAM_ID=${TEAM_ID:-4TWS7E2EPE}
IDENTITY=${DEVELOPER_ID:-$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: [^\"]*($TEAM_ID)\)\".*/\1/p" | head -1)}
IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
NOTARY_PROFILE=${NOTARY_PROFILE:-live-translate-notary}
ENTITLEMENTS="$ROOT/scripts/LiveTranslate.entitlements"

if [[ -n "$IDENTITY" ]]; then
  echo "==> Sign with $IDENTITY (hardened runtime)"
  # Inside out: every Mach-O in the bundled runtime and frameworks, then the app.
  find "$APP/Contents" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -111 \) -print0 |
    while IFS= read -r -d '' file; do
      if file "$file" | grep -q "Mach-O"; then
        codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$file"
      fi
    done
  codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
elif DEV_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1); [[ -n "$DEV_IDENTITY" ]]; then
  # Not enough for Gatekeeper, but a stable identity: macOS remembers Microphone and Screen
  # Recording permission across updates. An ad-hoc signature is a new app on every build.
  echo "==> Sign with $DEV_IDENTITY (no Developer ID, so Gatekeeper will warn; permissions persist)"
  find "$APP/Contents" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -111 \) -print0 |
    while IFS= read -r -d '' file; do
      if file "$file" | grep -q "Mach-O"; then
        codesign --force --sign "$DEV_IDENTITY" "$file"
      fi
    done
  codesign --force --sign "$DEV_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "==> Sign (ad hoc): no certificate, so Gatekeeper will warn and permissions are asked again after each update"
  codesign --force --deep --sign - "$APP"
  codesign --verify --deep --strict "$APP"
fi

echo "==> DMG"
mkdir -p "$OUT"
STAGE=$(mktemp -d)
# Installed as "Live Translate.app", the name people see in Finder and Applications.
cp -R "$APP" "$STAGE/Live Translate.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/LiveTranslate-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Live Translate $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "==> Notarize"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  else
    echo "==> Not notarized: create the profile once with"
    echo "    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id <team>"
  fi
fi
shasum -a 256 "$DMG"
du -h "$DMG"
