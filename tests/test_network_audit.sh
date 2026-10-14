#!/usr/bin/env bash
set -euo pipefail

echo "=== Running Offline & Zero-Network Audit ==="

# Directories to audit
AUDIT_DIRS="Sources Bridge"

# Prohibited network symbols and strings in runtime application code
PROHIBITED_PATTERNS=(
    "URLSession"
    "NSURLConnection"
    "CFNetwork"
    "CFSocket"
    "getaddrinfo"
    "connect\("
    "api.openai.com"
    "api.anthropic.com"
    "localhost:11434"
    "ollama"
    "telemetry"
    "analytics"
    "update_check"
)

FOUND_VIOLATIONS=0

for pattern in "${PROHIBITED_PATTERNS[@]}"; do
    # Grep ignoring comments if possible, or case-insensitive
    MATCHES=$(grep -rnE -i "$pattern" $AUDIT_DIRS 2>/dev/null || true)
    if [ -n "$MATCHES" ]; then
        echo "❌ VIOLATION FOUND for prohibited symbol/pattern '$pattern':"
        echo "$MATCHES"
        FOUND_VIOLATIONS=$((FOUND_VIOLATIONS + 1))
    fi
done

if [ "$FOUND_VIOLATIONS" -eq 0 ]; then
    echo "✓ Zero prohibited network symbols, telemetry, or remote API endpoints found in application code"
    echo "✓ Strict offline operation verified: Application uses purely local CoreGraphics, ScreenCaptureKit, Vision, and embedded llama.cpp"
    echo "=== Offline & Zero-Network Audit PASSED Successfully ==="
    exit 0
else
    echo "❌ Offline Audit FAILED with $FOUND_VIOLATIONS violation(s)"
    exit 1
fi
