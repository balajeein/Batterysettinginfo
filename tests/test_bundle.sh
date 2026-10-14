#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="build/Batterysettinginfo.app"

echo "=== Running App Bundle & Packaging Tests ==="

if [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ FAILED: App bundle does not exist at $APP_BUNDLE"
    exit 1
fi
echo "✓ App bundle exists at $APP_BUNDLE"

# 1. Check Info.plist
PLIST="$APP_BUNDLE/Contents/Info.plist"
if [ ! -f "$PLIST" ]; then
    echo "❌ FAILED: Info.plist missing from $PLIST"
    exit 1
fi
echo "✓ Info.plist exists"

# 2. Check LSUIElement
if ! grep -q "<key>LSUIElement</key>" "$PLIST" || ! grep -A 1 "<key>LSUIElement</key>" "$PLIST" | grep -q "<true/>"; then
    echo "❌ FAILED: LSUIElement is not set to true in Info.plist"
    exit 1
fi
echo "✓ Info.plist verified: LSUIElement = true (No Dock icon, menu bar only)"

# 3. Check executable
EXEC="$APP_BUNDLE/Contents/MacOS/Batterysettinginfo"
if [ ! -x "$EXEC" ]; then
    echo "❌ FAILED: Executable missing or not executable at $EXEC"
    exit 1
fi
echo "✓ Main executable exists and has execute permissions"

# 4. Check Frameworks
FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/libLlamaBridge.dylib"
if [ ! -f "$FRAMEWORK" ]; then
    echo "❌ FAILED: libLlamaBridge.dylib missing from $FRAMEWORK"
    exit 1
fi
echo "✓ Embedded libLlamaBridge.dylib is bundled in Contents/Frameworks"

# 5. Check Codesign
if ! codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null; then
    echo "❌ FAILED: Code signature verification failed"
    exit 1
fi
echo "✓ Code signature is valid and verified"

# 6. Test App Launch & Process Stability
"$EXEC" &
APP_PID=$!
sleep 2

if ps -p "$APP_PID" > /dev/null; then
    echo "✓ Application launched successfully (PID $APP_PID) and is running stably"
else
    echo "❌ FAILED: Application process crashed or exited immediately"
    exit 1
fi

# Clean shutdown
kill -TERM "$APP_PID"
wait "$APP_PID" 2>/dev/null || true
echo "✓ Application terminated cleanly"

echo "=== All App Bundle & Packaging Tests PASSED Successfully ==="
