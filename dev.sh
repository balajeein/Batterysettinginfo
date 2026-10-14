#!/usr/bin/env bash
# ==============================================================================
# Batterysettinginfo Development Workflow Script
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

APP_BUNDLE="build/Batterysettinginfo.app"
PROCESS_NAME="Batterysettinginfo"

usage() {
    echo "Usage: ./dev.sh [build | run | stop | test | clean]"
    echo ""
    echo "Commands:"
    echo "  build   Build the application and package Batterysettinginfo.app"
    echo "  run     Build if needed, then launch the packaged menu bar application"
    echo "  stop    Stop only this application's running process"
    echo "  test    Run automated unit, integration, bundle, and privacy audit tests"
    echo "  clean   Remove generated build artifacts without deleting code or models"
    echo ""
}

cmd_build() {
    echo "===> Building Batterysettinginfo..."
    ./build.sh
}

cmd_run() {
    if [ ! -d "$APP_BUNDLE" ]; then
        echo "===> App bundle not found, building first..."
        cmd_build
    fi

    cmd_stop || true

    echo "===> Launching $APP_BUNDLE..."
    open "$APP_BUNDLE"
    sleep 1

    PID=$(pgrep -f "$APP_BUNDLE/Contents/MacOS/$PROCESS_NAME" || true)
    if [ -n "$PID" ]; then
        echo "✓ Batterysettinginfo is actively running in background menu bar (PID: $PID)"
        echo "  Menu bar status icon: 🔋"
        echo "  Trigger shortcut: Semicolon (;) + Apostrophe (') pressed together"
    else
        echo "❌ ERROR: Application failed to start"
        exit 1
    fi
}

cmd_stop() {
    echo "===> Stopping Batterysettinginfo process..."
    # Match only the specific binary path to avoid terminating unrelated processes
    PIDS=$(pgrep -f "Contents/MacOS/$PROCESS_NAME" || true)
    if [ -n "$PIDS" ]; then
        echo "Terminating process(es): $PIDS"
        kill -TERM $PIDS 2>/dev/null || true
        sleep 0.5
        # Force kill if still lingering
        kill -9 $PIDS 2>/dev/null || true
        echo "✓ Application process stopped"
    else
        echo "ℹ️ No running Batterysettinginfo process found"
    fi
}

cmd_test() {
    echo "======================================================================"
    echo " Running Automated Test Suite: Batterysettinginfo"
    echo "======================================================================"

    if [ ! -f "build/libLlamaBridge.dylib" ]; then
        echo "===> libLlamaBridge.dylib not found, running build first..."
        cmd_build
    fi

    mkdir -p /tmp/battery_tests

    # 1. QuestionParser Unit Tests
    echo ""
    echo "--- [1/5] QuestionParser Unit Tests ---"
    swiftc tests/test_parser.swift Sources/Batterysettinginfo/QuestionParser.swift \
        -o /tmp/battery_tests/run_test_parser
    /tmp/battery_tests/run_test_parser

    # 2. Vision OCR & Pipeline Integration Test
    echo ""
    echo "--- [2/5] Vision OCR & Pipeline Integration Test ---"
    swiftc tests/test_ocr.swift Sources/Batterysettinginfo/OCRService.swift Sources/Batterysettinginfo/QuestionParser.swift \
        -o /tmp/battery_tests/run_test_ocr
    /tmp/battery_tests/run_test_ocr

    # 3. Embedded llama.cpp Native Bridge Test
    echo ""
    echo "--- [3/5] Embedded llama.cpp Native Bridge Test ---"
    swiftc tests/test_bridge.swift \
        Sources/Batterysettinginfo/AppConfiguration.swift \
        Sources/Batterysettinginfo/LocalInferenceEngine.swift \
        Sources/Batterysettinginfo/QuestionParser.swift \
        -Lbuild -lLlamaBridge \
        -Xlinker -rpath -Xlinker "$REPO_ROOT/build" \
        -o /tmp/battery_tests/run_test_bridge
    /tmp/battery_tests/run_test_bridge

    # 4. App Bundle Structure & Stability Test
    echo ""
    echo "--- [4/5] App Bundle Structure & Launch Stability Test ---"
    ./tests/test_bundle.sh

    # 5. Offline & Zero-Network Audit Test
    echo ""
    echo "--- [5/5] Offline & Zero-Network Audit Test ---"
    ./tests/test_network_audit.sh

    echo ""
    echo "======================================================================"
    echo " ✓ ALL AUTOMATED TESTS PASSED SUCCESSFULLY"
    echo "======================================================================"
}

cmd_clean() {
    echo "===> Cleaning build artifacts..."
    rm -rf build/Batterysettinginfo
    rm -rf build/libLlamaBridge.dylib
    rm -rf build/Batterysettinginfo.app
    rm -rf /tmp/battery_tests
    echo "✓ Cleaned application build outputs (source code and user models preserved)"
}

# If no arguments provided, run default development workflow
COMMAND="${1:-}"

if [ -z "$COMMAND" ]; then
    echo "No command provided. Running default development workflow (build + test)..."
    echo ""
    usage
    cmd_build
    cmd_test
    exit 0
fi

case "$COMMAND" in
    build)
        cmd_build
        ;;
    run)
        cmd_run
        ;;
    stop)
        cmd_stop
        ;;
    test)
        cmd_test
        ;;
    clean)
        cmd_clean
        ;;
    *)
        echo "❌ Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
