#!/bin/bash
# VPS Proxy Hub - WireGuard Utilities
# Shared functions for WireGuard installation, configuration, and peer management
# Used by both VPS and home machine setup scripts

set -euo pipefail

# Source shared utilities
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/utils.sh"

# =============================================================================
# WIREGUARD INSTALLATION
# =============================================================================

# Install WireGuard on any supported distribution
install_wireguard() {
    log "Installing WireGuard..."
    
    # Check if WireGuard is already installed
    if command -v wg &> /dev/null; then
        log "WireGuard is already installed"
        return 0
    fi
    
    if command -v apt-get &> /dev/null; then
        # Ubuntu/Debian installation
        apt-get update
        
        # Check Ubuntu/Debian version for installation method
        if grep -q "Ubuntu 18.04\|Ubuntu 16.04\|Debian.*9" /etc/os-release; then
            # Older versions need repository addition
            log "Installing WireGuard on older Ubuntu/Debian..."
            apt-get install -y software-properties-common
            add-apt-repository ppa:wireguard/wireguard -y
            apt-get update
        fi
        
        apt-get install -y wireguard wireguard-tools
        
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL installation
        log "Installing WireGuard on CentOS/RHEL..."
        
        # Install EPEL repository if not present
        if ! yum repolist | grep -q epel; then
            yum install -y epel-release
        fi
        
        # Install ELRepo for WireGuard on older CentOS versions
        if grep -q "CentOS.*7\|Red Hat.*7" /etc/os-release; then
            yum install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm
            yum --enablerepo=elrepo-kernel install -y kmod-wireguard wireguard-tools
        else
            yum install -y wireguard-tools
        fi
        
    elif command -v dnf &> /dev/null; then
        # Fedora installation
        log "Installing WireGuard on Fedora..."
        dnf install -y wireguard-tools
        
    else
        log_error "Unsupported distribution for automatic WireGuard installation"
        log "Please install WireGuard manually and re-run this script"
        exit 1
    fi
    
    # Verify installation
    if command -v wg &> /dev/null; then
        log_success "WireGuard installed successfully"
        wg --version
    else
        log_error "WireGuard installation failed"
        exit 1
    fi
}

# Install resolvconf for home machines (graceful fallback if unavailable)
install_resolvconf() {
    log "Installing resolvconf for DNS management..."
    
    if command -v apt-get &> /dev/null; then
        # Try to install resolvconf, but don't fail if unavailable
        if apt-get install -y resolvconf 2>/dev/null; then
            log_success "resolvconf installed successfully"
        else
            log_warning "resolvconf not available - DNS= lines in WireGuard config may be ignored"
            log "This is usually fine on modern systems with systemd-resolved"
        fi
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL typically handle DNS differently
        log "CentOS/RHEL detected - using NetworkManager for DNS management"
    elif command -v dnf &> /dev/null; then
        # Fedora typically has good DNS handling built-in
        log "Fedora detected - using systemd-resolved for DNS management"
    else
        log_warning "Unknown distribution - DNS configuration may need manual setup"
    fi
}

# =============================================================================
# DIRECTORY SETUP
# =============================================================================

# Setup WireGuard directories (parameterized for VPS vs Home)
# Usage: setup_wireguard_directories [vps|home]
setup_wireguard_directories() {
    local mode="${1:-generic}"
    
    log "Setting up WireGuard directory structure..."
    
    # Create basic WireGuard directory
    ensure_directory "/etc/wireguard" "700"
    
    if [[ "$mode" == "vps" ]]; then
        # VPS-specific directories
        local peers_dir
        peers_dir=$(get_config_value "vps.wireguard.peers_dir" "/etc/wireguard/peers")
        ensure_directory "$peers_dir" "700"
        
        # Create additional directories for organization
        ensure_directory "/etc/wireguard/backup" "700"
        
    elif [[ "$mode" == "home" ]]; then
        # Home machine directories
        ensure_directory "/etc/wireguard/keys" "700"
        ensure_directory "/etc/wireguard/backup" "700"
        
    else
        # Generic setup - minimal directories
        ensure_directory "/etc/wireguard/backup" "700"
    fi
    
    log_success "WireGuard directories created"
}

# =============================================================================
# KEY MANAGEMENT
# =============================================================================

# Setup VPS WireGuard keys
setup_vps_keys() {
    log "Setting up VPS WireGuard keys..."
    
    local private_key_path public_key_path
    private_key_path=$(get_config_value "vps.wireguard.private_key_path" "/etc/wireguard/vps-private.key")
    public_key_path=$(get_config_value "vps.wireguard.public_key_path" "/etc/wireguard/vps-public.key")
    
    # Generate private key if it doesn't exist
    if [[ ! -f "$private_key_path" ]]; then
        log "Generating VPS private key..."
        generate_wg_private_key > "$private_key_path"
        chmod 600 "$private_key_path"
        log_success "VPS private key generated: $private_key_path"
    else
        log "VPS private key already exists: $private_key_path"
    fi
    
    # Generate public key from private key
    if [[ ! -f "$public_key_path" ]] || [[ "$private_key_path" -nt "$public_key_path" ]]; then
        log "Generating VPS public key..."
        generate_wg_public_key "$(cat "$private_key_path")" > "$public_key_path"
        chmod 644 "$public_key_path"
        log_success "VPS public key generated: $public_key_path"
        
        # Display the public key for configuration
        local public_key
        public_key=$(cat "$public_key_path")
        log "VPS public key: $public_key"
        log "Add this to your config.yaml under vps.wireguard.public_key"
    else
        log "VPS public key already exists: $public_key_path"
    fi
}

# Setup home machine WireGuard keys
# Usage: setup_home_keys "peer_name"
setup_home_keys() {
    local peer_name="$1"
    
    log "Setting up home machine WireGuard keys for peer: $peer_name"
    
    local private_key_path public_key_path
    private_key_path=$(get_peer_config_with_defaults "$peer_name" "private_key_path")
    public_key_path=$(get_peer_config_with_defaults "$peer_name" "public_key_path")
    
    # Fallback to defaults if not configured
    if [[ -z "$private_key_path" ]]; then
        private_key_path="/etc/wireguard/home-private.key"
    fi
    if [[ -z "$public_key_path" ]]; then
        public_key_path="/etc/wireguard/home-public.key"
    fi
    
    # Generate private key if it doesn't exist
    if [[ ! -f "$private_key_path" ]]; then
        log "Generating home machine private key..."
        generate_wg_private_key > "$private_key_path"
        chmod 600 "$private_key_path"
        log_success "Home private key generated: $private_key_path"
    else
        log "Home private key already exists: $private_key_path"
    fi
    
    # Generate public key from private key
    if [[ ! -f "$public_key_path" ]] || [[ "$private_key_path" -nt "$public_key_path" ]]; then
        log "Generating home machine public key..."
        generate_wg_public_key "$(cat "$private_key_path")" > "$public_key_path"
        chmod 644 "$public_key_path"
        log_success "Home public key generated: $public_key_path"
    else
        log "Home public key already exists: $public_key_path"
    fi
    
    # Display public key for VPS configuration
    display_peer_info "$peer_name" "$public_key_path"
}

# =============================================================================
# KERNEL MODULE MANAGEMENT
# =============================================================================

# Enable WireGuard kernel module
enable_wireguard_module() {
    log "Enabling WireGuard kernel module..."
    
    # Try to load the module
    if modprobe wireguard 2>/dev/null; then
        log_success "WireGuard kernel module loaded"
    else
        log_warning "Could not load WireGuard kernel module - this may be normal on some systems"
        log "WireGuard may use userspace implementation or be built into kernel"
    fi
    
    # Verify WireGuard is working
    if wg --help &>/dev/null; then
        log_success "WireGuard is functional"
    else
        log_error "WireGuard is not working properly"
        exit 1
    fi
}

# =============================================================================
# PEER CONFIGURATION
# =============================================================================

# Add peer to WireGuard configuration file
# Usage: add_peer_to_config "config_path" "peer_name" "peers_dir"
add_peer_to_config() {
    local config_path="$1"
    local peer_name="$2"
    local peers_dir="$3"
    
    if [[ -z "$peer_name" ]]; then
        return 0
    fi
    
    log "Processing peer: $peer_name"
    
    # Get peer configuration
    local peer_address peer_keepalive public_key_file
    
    if command -v yq &> /dev/null; then
        peer_address=$(yq eval ".peers[] | select(.name == \"$peer_name\") | .address" "$CONFIG_FILE")
        peer_keepalive=$(yq eval ".peers[] | select(.name == \"$peer_name\") | .keepalive" "$CONFIG_FILE")
    else
        # Basic parsing - find peer section and extract values
        peer_address=$(awk "/name:.*$peer_name/,/^[[:space:]]*-|^[^[:space:]]/ { if(/address:/) print \$2 }" "$CONFIG_FILE" | tr -d '"'"'" | head -1)
        peer_keepalive=$(awk "/name:.*$peer_name/,/^[[:space:]]*-|^[^[:space:]]/ { if(/keepalive:/) print \$2 }" "$CONFIG_FILE" | head -1)
    fi
    
    # Set defaults if not specified
    peer_keepalive=${peer_keepalive:-25}
    
    # Look for peer public key file
    public_key_file="$peers_dir/${peer_name}.pub"
    
    if [[ -f "$public_key_file" ]]; then
        local public_key
        public_key=$(cat "$public_key_file")
        
        # Add peer section to config
        cat >> "$config_path" << EOF

# Peer: $peer_name
[Peer]
PublicKey = $public_key
AllowedIPs = $peer_address
PersistentKeepalive = $peer_keepalive

EOF
        log "Added peer $peer_name to configuration"
    else
        log_warning "Public key not found for peer $peer_name: $public_key_file"
        log "Run home setup on the peer machine and copy the public key to this file"
        
        # Add placeholder peer section
        cat >> "$config_path" << EOF

# Peer: $peer_name (PUBLIC KEY NEEDED)
# [Peer]
# PublicKey = PASTE_PUBLIC_KEY_HERE
# AllowedIPs = $peer_address
# PersistentKeepalive = $peer_keepalive

EOF
    fi
}

# Add all configured peers to WireGuard configuration
# Usage: add_all_peers_to_config "config_path" "peers_dir"
add_all_peers_to_config() {
    local config_path="$1"
    local peers_dir="$2"
    
    log "Adding peers to WireGuard configuration..."
    
    # Get peers from config file
    if command -v yq &> /dev/null; then
        yq eval '.peers[] | .name' "$CONFIG_FILE" | while IFS= read -r peer_name; do
            add_peer_to_config "$config_path" "$peer_name" "$peers_dir"
        done
    else
        # Basic parsing for peer names
        grep -A 20 "^peers:" "$CONFIG_FILE" | grep "name:" | sed 's/.*name: *["'\'']*//' | sed 's/["'\'']*.*//' | while IFS= read -r peer_name; do
            if [[ -n "$peer_name" ]]; then
                add_peer_to_config "$config_path" "$peer_name" "$peers_dir"
            fi
        done
    fi
}

# Log successful loading
log_debug "WireGuard utilities loaded successfully"