#!/bin/bash
# VPS Proxy Hub - Shared Utilities Library
# Central location for common functions used across all scripts
# Provides logging, YAML parsing, validation, and system utilities

# Prevent multiple sourcing to avoid circular dependency issues
[[ -n "${UTILS_SH_LOADED:-}" ]] && return 0
readonly UTILS_SH_LOADED=1

set -euo pipefail

# =============================================================================
# GLOBAL CONFIGURATION
# =============================================================================

# Colors for output formatting (only set if not already defined)
if [[ -z "${RED:-}" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly NC='\033[0m' # No Color
fi

# Global variables (can be overridden by sourcing scripts)
CONFIG_FILE="${CONFIG_FILE:-$(dirname "${BASH_SOURCE[0]}")/../config.yaml}"
LOG_FILE="${LOG_FILE:-/var/log/vps-proxy-hub.log}"

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

# Log informational messages
log() {
    local prefix="${LOG_PREFIX:-[INFO]}"
    echo -e "${BLUE}${prefix}${NC} $*" | tee -a "$LOG_FILE" >&2
}

# Log success messages
log_success() {
    local prefix="${LOG_PREFIX:-[SUCCESS]}"
    echo -e "${GREEN}${prefix}${NC} $*" | tee -a "$LOG_FILE" >&2
}

# Log warning messages
log_warning() {
    local prefix="${LOG_PREFIX:-[WARNING]}"
    echo -e "${YELLOW}${prefix}${NC} $*" | tee -a "$LOG_FILE" >&2
}

# Log error messages
log_error() {
    local prefix="${LOG_PREFIX:-[ERROR]}"
    echo -e "${RED}${prefix}${NC} $*" | tee -a "$LOG_FILE" >&2
}

# Log debug messages (only shown if DEBUG=1)
log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        local prefix="${LOG_PREFIX:-[DEBUG]}"
        echo -e "${BLUE}${prefix}${NC} $*" | tee -a "$LOG_FILE" >&2
    fi
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

# Check if running as root - required for most system operations
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Check if configuration file exists and is readable
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        log "Please copy config.yaml.example to config.yaml and customize it"
        exit 1
    fi
    
    if [[ ! -r "$CONFIG_FILE" ]]; then
        log_error "Config file is not readable: $CONFIG_FILE"
        exit 1
    fi
}

# =============================================================================
# YAML CONFIGURATION PARSING
# =============================================================================

# Install yq YAML parser if not present (improves parsing reliability)
install_yq() {
    if ! command -v yq &> /dev/null; then
        log "Installing yq for YAML parsing..."
        if command -v snap &> /dev/null; then
            snap install yq
        elif command -v wget &> /dev/null; then
            local yq_version="v4.35.2"
            local yq_binary="yq_linux_amd64"
            wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${yq_version}/${yq_binary}"
            chmod +x /usr/local/bin/yq
        else
            log_warning "Could not install yq. Using basic YAML parsing."
        fi
    fi
}

# Get a single configuration value from YAML
# Usage: get_config_value "path.to.key" "default_value"
get_config_value() {
    local key="$1"
    local default="${2:-}"
    
    if command -v yq &> /dev/null; then
        yq eval ".$key" "$CONFIG_FILE" 2>/dev/null || echo "$default"
    else
        # Basic YAML parsing fallback for simple key paths
        local value
        value=$(grep -E "^\s*${key##*.}:" "$CONFIG_FILE" | head -1 | \
               sed 's/.*:\s*//' | sed 's/["'\'']//g' || echo "$default")
        echo "$value"
    fi
}

# Get array values from YAML configuration
# Usage: get_config_array "path.to.array"
get_config_array() {
    local key="$1"
    
    if command -v yq &> /dev/null; then
        yq eval ".$key[]" "$CONFIG_FILE" 2>/dev/null
    else
        # Basic array parsing - assumes simple YAML format
        grep -A 10 "^$key:" "$CONFIG_FILE" | \
            grep "^\s*-" | \
            sed 's/^\s*-\s*//' | \
            sed 's/["'\'']//g'
    fi
}

# Get peer configuration by name
# Usage: get_peer_config "peer_name" "config_key" "default_value"
get_peer_config() {
    local peer_name="$1"
    local key="$2"
    local default="${3:-}"
    
    if command -v yq &> /dev/null; then
        yq eval ".peers[] | select(.name == \"$peer_name\") | .$key" "$CONFIG_FILE" 2>/dev/null || echo "$default"
    else
        # Basic parsing - find peer section and extract key
        awk "/name:.*\"?${peer_name}\"?/,/^[[:space:]]*-[[:space:]]*name:|^[^[:space:]]/ {
            if (/${key}:/) {
                gsub(/.*${key}:[[:space:]]*[\"']?/, \"\")
                gsub(/[\"'].*/, \"\")
                print \$0
                exit
            }
        }" "$CONFIG_FILE" || echo "$default"
    fi
}

# Validate that a peer name exists in configuration
# Usage: validate_peer_name "peer_name"
validate_peer_name() {
    local peer_name="$1"
    
    if command -v yq &> /dev/null; then
        yq eval ".peers[] | select(.name == \"$peer_name\") | .name" "$CONFIG_FILE" 2>/dev/null | grep -q "$peer_name"
    else
        grep -q "name:.*\"\\?${peer_name}\"\\?" "$CONFIG_FILE"
    fi
}

# =============================================================================
# FILE AND BACKUP OPERATIONS
# =============================================================================

# Create timestamped backup of a file before modification
# Usage: backup_file "/path/to/file"
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup_name="${file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$file" "$backup_name"
        log "Backed up $file -> $backup_name"
    fi
}

# Create directory if it doesn't exist with specified permissions
# Usage: ensure_directory "/path/to/dir" "755"
ensure_directory() {
    local dir="$1"
    local mode="${2:-755}"
    
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        chmod "$mode" "$dir"
        log "Created directory: $dir"
    fi
}

# Template substitution with variable replacement
# Usage: substitute_template "template.conf" "output.conf" "VAR1=value1" "VAR2=value2"
substitute_template() {
    local template_file="$1"
    local output_file="$2"
    shift 2
    
    if [[ ! -f "$template_file" ]]; then
        log_error "Template file not found: $template_file"
        return 1
    fi
    
    local content
    content=$(cat "$template_file")
    
    # Replace variables passed as key=value pairs
    while [[ $# -gt 0 ]]; do
        local pair="$1"
        local key="${pair%%=*}"
        local value="${pair#*=}"
        content="${content//\{\{${key}\}\}/$value}"
        shift
    done
    
    echo "$content" > "$output_file"
    log "Generated $output_file from template"
}

# =============================================================================
# WIREGUARD KEY MANAGEMENT
# =============================================================================

# Generate a new WireGuard private key
generate_wg_private_key() {
    wg genkey
}

# Generate WireGuard public key from private key
# Usage: generate_wg_public_key "private_key_here"
generate_wg_public_key() {
    local private_key="$1"
    echo "$private_key" | wg pubkey
}

# =============================================================================
# PACKAGE MANAGEMENT
# =============================================================================

# Check if a package is installed (cross-distribution)
# Usage: package_installed "package_name"
package_installed() {
    local package="$1"
    if command -v dpkg &> /dev/null; then
        # Debian/Ubuntu
        dpkg -l | grep -q "^ii\s*$package"
    elif command -v rpm &> /dev/null; then
        # CentOS/RHEL/Fedora
        rpm -q "$package" &> /dev/null
    else
        return 1
    fi
}

# Install package using appropriate package manager
# Usage: install_package "package_name"
install_package() {
    local package="$1"
    
    if package_installed "$package"; then
        log "$package is already installed"
        return 0
    fi
    
    log "Installing $package..."
    
    if command -v apt-get &> /dev/null; then
        # Debian/Ubuntu
        apt-get update -qq
        apt-get install -y "$package"
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL 7
        yum install -y "$package"
    elif command -v dnf &> /dev/null; then
        # CentOS/RHEL 8+/Fedora
        dnf install -y "$package"
    else
        log_error "No supported package manager found"
        exit 1
    fi
}

# =============================================================================
# SYSTEM SERVICE MANAGEMENT
# =============================================================================

# Check if a systemd service is currently running
# Usage: service_running "nginx"
service_running() {
    local service="$1"
    systemctl is-active --quiet "$service"
}

# Enable and start a systemd service
# Usage: enable_service "nginx"
enable_service() {
    local service="$1"
    log "Enabling and starting $service"
    systemctl enable "$service"
    systemctl start "$service"
}

# Restart a systemd service
# Usage: restart_service "nginx"
restart_service() {
    local service="$1"
    log "Restarting $service"
    systemctl restart "$service"
}

# Wait for a service to become ready with timeout
# Usage: wait_for_service "nginx" 30
wait_for_service() {
    local service="$1"
    local timeout="${2:-30}"
    local count=0
    
    log "Waiting for $service to be ready..."
    while ! service_running "$service"; do
        if [[ $count -ge $timeout ]]; then
            log_error "$service failed to start within $timeout seconds"
            return 1
        fi
        sleep 1
        ((count++))
    done
    log_success "$service is running"
}

# =============================================================================
# NETWORK AND VALIDATION UTILITIES
# =============================================================================

# Validate IPv4 address format
# Usage: validate_ip "192.168.1.1"
validate_ip() {
    local ip="$1"
    [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

# Get the default network interface (for routing)
get_default_interface() {
    ip route show default | awk '/default/ { print $5 ; exit }'
}

# Test if a TCP port is open on a host
# Usage: port_open "example.com" 80 5
port_open() {
    local host="$1"
    local port="$2"
    local timeout="${3:-5}"
    
    timeout "$timeout" bash -c "</dev/tcp/$host/$port" 2>/dev/null
}

# =============================================================================
# USER INTERFACE HELPERS
# =============================================================================

# Display formatted peer information for VPS setup
# Usage: display_peer_info "peer_name" "/path/to/public_key_file"
display_peer_info() {
    local peer_name="$1"
    local public_key_file="$2"
    
    if [[ -f "$public_key_file" ]]; then
        local public_key
        public_key=$(cat "$public_key_file")
        
        echo ""
        log_success "Home machine '$peer_name' setup completed!"
        echo ""
        echo "═══════════════════════════════════════════════════════════════════"
        echo "COPY THE FOLLOWING COMMAND TO RUN ON YOUR VPS:"
        echo "═══════════════════════════════════════════════════════════════════"
        echo ""
        echo "add-peer-key $peer_name '$public_key'"
        echo ""
        echo "═══════════════════════════════════════════════════════════════════"
        echo ""
        log "After running the command on the VPS, WireGuard will restart"
        log "and this peer will be able to connect to the tunnel."
    else
        log_error "Public key file not found: $public_key_file"
    fi
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Load configuration utilities for enhanced config handling
source "$(dirname "${BASH_SOURCE[0]}")/config_utils.sh"

# Log that utilities have been loaded
log_debug "Shared utilities loaded successfully"

# Export functions that might be useful to have in subshells
export -f log log_success log_warning log_error log_debug
export -f check_root check_config
export -f get_config_value get_config_array get_peer_config validate_peer_name
export -f backup_file ensure_directory substitute_template
export -f generate_wg_private_key generate_wg_public_key
export -f package_installed install_package
export -f service_running enable_service restart_service wait_for_service
export -f validate_ip get_default_interface port_open
export -f display_peer_info