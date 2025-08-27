#!/bin/bash
# Home Machine Setup Utilities - Shared functions for home scripts
# Provides logging, YAML parsing, and common utilities

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
CONFIG_FILE="${CONFIG_FILE:-$(dirname "${BASH_SOURCE[0]}")/../../config.yaml}"
LOG_FILE="${LOG_FILE:-/var/log/vps-proxy-hub-home.log}"

# Logging functions
log() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Check if config file exists
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        log "Please copy config.yaml.example to config.yaml and customize it"
        exit 1
    fi
}

# Simple YAML parser - extracts values using yq if available, otherwise basic parsing
get_config_value() {
    local key="$1"
    local default="${2:-}"
    
    if command -v yq &> /dev/null; then
        yq eval ".$key" "$CONFIG_FILE" 2>/dev/null || echo "$default"
    else
        # Basic YAML parsing for simple key paths
        local value
        value=$(grep -E "^\s*${key##*.}:" "$CONFIG_FILE" | head -1 | sed 's/.*:\s*//' | sed 's/["'\'']//g' || echo "$default")
        echo "$value"
    fi
}

# Get peer configuration by name
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

# Install yq if not present (helps with YAML parsing)
install_yq() {
    if ! command -v yq &> /dev/null; then
        log "Installing yq for YAML parsing..."
        if command -v snap &> /dev/null; then
            snap install yq
        elif command -v wget &> /dev/null; then
            YQ_VERSION="v4.35.2"
            YQ_BINARY="yq_linux_amd64"
            wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}"
            chmod +x /usr/local/bin/yq
        else
            log_warning "Could not install yq. Using basic YAML parsing."
        fi
    fi
}

# Create backup of a file
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp "$file" "${file}.backup.$(date +%Y%m%d_%H%M%S)"
        log "Backed up $file"
    fi
}

# Generate WireGuard private key
generate_wg_private_key() {
    wg genkey
}

# Generate WireGuard public key from private key
generate_wg_public_key() {
    local private_key="$1"
    echo "$private_key" | wg pubkey
}

# Check if a package is installed (works on Debian/Ubuntu and CentOS/RHEL)
package_installed() {
    local package="$1"
    if command -v dpkg &> /dev/null; then
        dpkg -l | grep -q "^ii\s*$package"
    elif command -v rpm &> /dev/null; then
        rpm -q "$package" &> /dev/null
    else
        return 1
    fi
}

# Install package (auto-detects package manager)
install_package() {
    local package="$1"
    
    if package_installed "$package"; then
        log "$package is already installed"
        return 0
    fi
    
    log "Installing $package..."
    
    if command -v apt-get &> /dev/null; then
        apt-get update -qq
        apt-get install -y "$package"
    elif command -v yum &> /dev/null; then
        yum install -y "$package"
    elif command -v dnf &> /dev/null; then
        dnf install -y "$package"
    else
        log_error "No supported package manager found"
        exit 1
    fi
}

# Check if service is running
service_running() {
    local service="$1"
    systemctl is-active --quiet "$service"
}

# Start and enable service
enable_service() {
    local service="$1"
    log "Enabling and starting $service"
    systemctl enable "$service"
    systemctl start "$service"
}

# Restart service
restart_service() {
    local service="$1"
    log "Restarting $service"
    systemctl restart "$service"
}

# Wait for service to be ready
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

# Create directory if it doesn't exist
ensure_directory() {
    local dir="$1"
    local mode="${2:-755}"
    
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        chmod "$mode" "$dir"
        log "Created directory: $dir"
    fi
}

# Template substitution
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

# Validate IP address format
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Get network interface with default route
get_default_interface() {
    ip route show default | awk '/default/ { print $5 ; exit }'
}

# Test if port is open
port_open() {
    local host="$1"
    local port="$2"
    local timeout="${3:-5}"
    
    timeout "$timeout" bash -c "</dev/tcp/$host/$port" 2>/dev/null
}

# Check if peer name exists in config
validate_peer_name() {
    local peer_name="$1"
    
    if command -v yq &> /dev/null; then
        if yq eval ".peers[] | select(.name == \"$peer_name\") | .name" "$CONFIG_FILE" 2>/dev/null | grep -q "$peer_name"; then
            return 0
        else
            return 1
        fi
    else
        if grep -q "name:.*\"\\?${peer_name}\"\\?" "$CONFIG_FILE"; then
            return 0
        else
            return 1
        fi
    fi
}

# Display peer public key in a format ready for VPS
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

log "Home utilities loaded successfully"