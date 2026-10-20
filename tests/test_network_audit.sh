#!/usr/bin/env bash
set -euo pipefail

echo "=== Running Network Privacy Audit ==="

# Directories to audit
AUDIT_DIRS="Sources Bridge"

# Prohibited unrelated network symbols and endpoints in runtime application code.
# OnlineInferenceEngine.swift is the explicit, user-selected NVIDIA Online mode.
PROHIBITED_PATTERNS=(
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

UNEXPECTED_NETWORK_CODE=$(grep -rnE -i "URLSession|URLRequest|https?://" Sources Bridge 2>/dev/null \
    | grep -v "Sources/Batterysettinginfo/OnlineInferenceEngine.swift" \
    | grep -v "Sources/Batterysettinginfo/README" || true)
if [ -n "$UNEXPECTED_NETWORK_CODE" ]; then
    echo "❌ UNEXPECTED NETWORK CODE FOUND OUTSIDE ONLINE MODE:"
    echo "$UNEXPECTED_NETWORK_CODE"
    FOUND_VIOLATIONS=$((FOUND_VIOLATIONS + 1))
fi

if ! grep -q "integrate.api.nvidia.com/v1/chat/completions" Sources/Batterysettinginfo/OnlineInferenceEngine.swift; then
    echo "❌ NVIDIA online endpoint is missing from the explicit online implementation"
    FOUND_VIOLATIONS=$((FOUND_VIOLATIONS + 1))
fi

if ! grep -q "OnlineSettings.shared.isOnlineMode" Sources/Batterysettinginfo/AppDelegate.swift; then
    echo "❌ Online mode is not explicitly gated by the user's selected mode"
    FOUND_VIOLATIONS=$((FOUND_VIOLATIONS + 1))
fi

if [ "$FOUND_VIOLATIONS" -eq 0 ]; then
    echo "✓ No unrelated network symbols, telemetry, or remote API endpoints found"
    echo "✓ Network access is isolated to the explicit NVIDIA Online mode"
    echo "✓ Offline mode remains local and does not initiate a network request"
    echo "=== Network Privacy Audit PASSED Successfully ==="
    exit 0
else
    echo "❌ Offline Audit FAILED with $FOUND_VIOLATIONS violation(s)"
    exit 1
fi
