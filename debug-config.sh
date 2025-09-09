#!/bin/bash
# Debug script to test config parsing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.current.yaml"

# Load shared utilities
source "$SCRIPT_DIR/shared/utils.sh"

echo "=== Testing config parsing ==="
echo "Config file: $CONFIG_FILE"
echo ""

echo "=== Sites found ==="
if command -v yq &> /dev/null; then
    echo "Using yq:"
    yq eval '.sites[] | .name' "$CONFIG_FILE" 2>/dev/null || echo "No sites found with yq"
else
    echo "Using fallback parser:"
    awk '/^sites:/,/^[a-zA-Z_]/ {
        if (/^\s*-\s*name:/) {
            gsub(/^\s*-\s*name:\s*["'"'"']?/, "")
            gsub(/["'"'"'].*$/, "")
            if (length($0) > 0) print $0
        }
    }' "$CONFIG_FILE"
fi

echo ""
echo "=== Peers found ==="
if command -v yq &> /dev/null; then
    echo "Using yq:"
    yq eval '.peers[] | .name' "$CONFIG_FILE" 2>/dev/null || echo "No peers found with yq"
else
    echo "Using fallback parser - checking peers section..."
fi

echo ""
echo "=== Testing peer dev-01 ==="
echo "Peer config:"
get_peer_config "dev-01" "address" || echo "Failed to get peer address"

echo ""
echo "=== Testing site dev-01 upstream ==="
if command -v yq &> /dev/null; then
    echo "Docker setting:"
    yq eval '.sites[] | select(.name == "dev-01") | .upstream.docker' "$CONFIG_FILE" 2>/dev/null || echo "null"
    echo "Port setting:"
    yq eval '.sites[] | select(.name == "dev-01") | .upstream.port' "$CONFIG_FILE" 2>/dev/null || echo "null"
    echo "Container port setting:"
    yq eval '.sites[] | select(.name == "dev-01") | .upstream.container_port' "$CONFIG_FILE" 2>/dev/null || echo "null"
else
    echo "No yq available for detailed parsing"
fi