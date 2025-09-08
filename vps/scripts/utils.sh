#!/bin/bash
# VPS Setup Utilities - Redirect to Shared Utilities
# This file sources the shared utility libraries for VPS scripts

set -euo pipefail

# Load shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../shared/utils.sh"

# Set default log file for VPS operations if not already set
LOG_FILE="${LOG_FILE:-/var/log/vps-proxy-hub.log}"