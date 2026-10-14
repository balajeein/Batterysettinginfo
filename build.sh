#!/usr/bin/env bash
# ==============================================================================
# Batterysettinginfo Build Script
# Native macOS Menu Bar Agent with Embedded llama.cpp and Apple Vision OCR
# ==============================================================================

set -euo pipefail

# Ensure brew and system binaries are in PATH
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

LLAMA_PINNED_TAG="b11620"
LLAMA_PINNED_COMMIT="21a19cd3be83099ca1b3d00f1d83cc7a40840d9f"
LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"

BUILD_DIR="$REPO_ROOT/build"
VENDOR_DIR="$REPO_ROOT/vendor"
LLAMA_DIR="$VENDOR_DIR/llama.cpp"
APP_NAME="Batterysettinginfo"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "======================================================================"
echo " Starting build: $APP_NAME"
echo " Date: $(date)"
echo " OS: $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. Environment & Tooling Validation
# ------------------------------------------------------------------------------
echo "[-] Validating development tools..."

check_tool() {
    if ! command -v "$1" &>/dev/null; then
        echo "❌ ERROR: Required tool '$1' not found in PATH." >&2
        exit 1
    fi
}

check_tool git
check_tool cmake
check_tool clang++
check_tool swiftc
check_tool xcrun
check_tool codesign

echo "✓ All required compiler and build tools found:"
echo "  - CMake: $(cmake --version | head -n 1)"
echo "  - Clang: $(clang++ --version | head -n 1)"
echo "  - Swift: $(swiftc --version | head -n 1)"

# ------------------------------------------------------------------------------
# 2. Pinned llama.cpp Integration (Hard requirement: No Ollama)
# ------------------------------------------------------------------------------
mkdir -p "$VENDOR_DIR"
if [ ! -d "$LLAMA_DIR/.git" ]; then
    echo "[-] Cloning pinned llama.cpp (tag: $LLAMA_PINNED_TAG, commit: $LLAMA_PINNED_COMMIT)..."
    git clone --depth 1 --branch "$LLAMA_PINNED_TAG" "$LLAMA_REPO" "$LLAMA_DIR"
else
    echo "✓ Pinned llama.cpp dependency directory exists at $LLAMA_DIR"
fi

# ------------------------------------------------------------------------------
# 3. Build llama.cpp Static Libraries with Metal Acceleration
# ------------------------------------------------------------------------------
LLAMA_BUILD_DIR="$LLAMA_DIR/build"
LLAMA_LIB="$LLAMA_BUILD_DIR/src/libllama.a"

if [ ! -f "$LLAMA_LIB" ]; then
    echo "[-] Configuring llama.cpp with Metal backend..."
    cmake -B "$LLAMA_BUILD_DIR" -S "$LLAMA_DIR" \
        -DGGML_METAL=ON \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_SERVER=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_BUILD_TYPE=Release

    echo "[-] Compiling llama.cpp static libraries with Apple Silicon Metal acceleration..."
    CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    cmake --build "$LLAMA_BUILD_DIR" --target llama -j"$CORES"
else
    echo "✓ llama.cpp static library already compiled: $LLAMA_LIB"
fi

# ------------------------------------------------------------------------------
# 4. Compile Native Bridge (C++ / Metal -> Swift C API)
# ------------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
BRIDGE_DYLIB="$BUILD_DIR/libLlamaBridge.dylib"

echo "[-] Compiling native LlamaBridge dynamic library..."
clang++ -std=c++17 -O3 -dynamiclib \
    -IBridge \
    -I"$LLAMA_DIR/include" \
    -I"$LLAMA_DIR/ggml/include" \
    -I"$LLAMA_DIR/ggml/src" \
    -DGGML_USE_METAL=1 \
    Bridge/LlamaBridge.cpp \
    "$LLAMA_BUILD_DIR/src/libllama.a" \
    "$LLAMA_BUILD_DIR/ggml/src/libggml.a" \
    "$LLAMA_BUILD_DIR/ggml/src/libggml-cpu.a" \
    "$LLAMA_BUILD_DIR/ggml/src/libggml-base.a" \
    "$LLAMA_BUILD_DIR/ggml/src/ggml-metal/libggml-metal.a" \
    "$LLAMA_BUILD_DIR/ggml/src/ggml-blas/libggml-blas.a" \
    -framework Metal -framework Foundation -framework Accelerate -lc++ \
    -install_name @rpath/libLlamaBridge.dylib \
    -o "$BRIDGE_DYLIB"

echo "✓ Built native bridge: $BRIDGE_DYLIB"

# ------------------------------------------------------------------------------
# 5. Compile Swift Application
# ------------------------------------------------------------------------------
SWIFT_EXEC="$BUILD_DIR/$APP_NAME"
echo "[-] Compiling native Swift AppKit application..."

swiftc \
    Sources/Batterysettinginfo/AppConfiguration.swift \
    Sources/Batterysettinginfo/FeedbackManager.swift \
    Sources/Batterysettinginfo/QuestionParser.swift \
    Sources/Batterysettinginfo/OCRService.swift \
    Sources/Batterysettinginfo/ScreenCaptureService.swift \
    Sources/Batterysettinginfo/LocalInferenceEngine.swift \
    Sources/Batterysettinginfo/ShortcutManager.swift \
    Sources/Batterysettinginfo/MenuBarController.swift \
    Sources/Batterysettinginfo/AppDelegate.swift \
    Sources/Batterysettinginfo/main.swift \
    -L"$BUILD_DIR" -lLlamaBridge \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -Xlinker -rpath -Xlinker @loader_path \
    -O \
    -o "$SWIFT_EXEC"

echo "✓ Compiled Swift binary: $SWIFT_EXEC"

# ------------------------------------------------------------------------------
# 6. Package .app Bundle
# ------------------------------------------------------------------------------
echo "[-] Packaging application bundle: $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$SWIFT_EXEC" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$BRIDGE_DYLIB" "$APP_BUNDLE/Contents/Frameworks/libLlamaBridge.dylib"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# ------------------------------------------------------------------------------
# 7. Local Development Code Signing
# ------------------------------------------------------------------------------
echo "[-] Applying local development ad-hoc code signature..."
codesign --force --deep -s - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "======================================================================"
echo " BUILD SUCCESSFUL"
echo " App Bundle: $APP_BUNDLE"
echo " LSUIElement: YES (Runs strictly as menu bar agent, no Dock icon)"
echo " Models Dir: ~/Library/Application Support/Batterysettinginfo/models/"
echo " To run: open \"$APP_BUNDLE\" or ./dev.sh run"
echo "======================================================================"
