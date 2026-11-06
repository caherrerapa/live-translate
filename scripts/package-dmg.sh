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

echo "==> Sign (ad hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> DMG"
mkdir -p "$OUT"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/LiveTranslate-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Live Translate $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
shasum -a 256 "$DMG"
du -h "$DMG"
