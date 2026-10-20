#!/usr/bin/env bash
# Build a distributable DMG containing the app and its local Qwen3-VL model.
# The regular build.sh / Batterysettinginfo.dmg remains lightweight.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"
APP_NAME="Batterysettinginfo"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MODEL_DIR="${HOME}/Library/Application Support/$APP_NAME/models"
OUTPUT_DMG="$BUILD_DIR/${APP_NAME}-SelfContained.dmg"

MODEL_FILE="$MODEL_DIR/Qwen3VL-4B-Instruct-Q4_K_M.gguf"
MMPROJ_FILE="$MODEL_DIR/mmproj-Qwen3VL-4B-Instruct-F16.gguf"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "ERROR: This package is built for Apple Silicon (arm64)." >&2
    exit 1
fi

for required_file in "$MODEL_FILE" "$MMPROJ_FILE"; do
    if [[ ! -f "$required_file" ]]; then
        echo "ERROR: Required model file is missing: $required_file" >&2
        exit 1
    fi
done

echo "[-] Building the application bundle..."
"$REPO_ROOT/build.sh"

STAGING_DIR="$(mktemp -d "$BUILD_DIR/self-contained-dmg.XXXXXX")"
cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

STAGED_APP="$STAGING_DIR/$APP_NAME.app"
echo "[-] Copying app and local model files into the self-contained bundle..."
ditto "$APP_BUNDLE" "$STAGED_APP"
cp "$MODEL_FILE" "$STAGED_APP/Contents/Resources/"
cp "$MMPROJ_FILE" "$STAGED_APP/Contents/Resources/"

SIGN_IDENTITY="$(security find-identity -p codesigning -v | grep -o '"[^"]*"' | head -n 1 | tr -d '"' || true)"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"
fi

echo "[-] Re-signing the bundle after adding model resources..."
codesign --force -s "$SIGN_IDENTITY" "$STAGED_APP/Contents/Frameworks/libLlamaBridge.dylib"
codesign --force --deep -s "$SIGN_IDENTITY" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

rm -f "$OUTPUT_DMG"
echo "[-] Creating self-contained DMG (this includes approximately 3 GB of model data)..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$OUTPUT_DMG"

hdiutil verify "$OUTPUT_DMG"

echo "======================================================================"
echo " SELF-CONTAINED DMG CREATED"
echo " DMG: $OUTPUT_DMG"
echo " Size: $(du -h "$OUTPUT_DMG" | awk '{print $1}')"
echo " Model: bundled inside Batterysettinginfo.app/Contents/Resources/"
echo " Architecture: Apple Silicon arm64"
echo "======================================================================"
