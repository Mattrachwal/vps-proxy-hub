#!/bin/bash
# VPS Setup - WireGuard Installation
# Installs WireGuard and sets up the basic configuration structure

set -euo pipefail

# Load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

main() {
    log "Starting WireGuard installation..."
    
    check_root
    check_config
    
    # Install WireGuard based on the distribution
    install_wireguard
    
    # Create WireGuard directory structure
    setup_wireguard_directories
    
    # Generate VPS keys if they don't exist
    setup_vps_keys
    
    # Enable WireGuard kernel module
    enable_wireguard_module
    
    log_success "WireGuard installation completed"
}

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

setup_wireguard_directories() {
    log "Setting up WireGuard directory structure..."
    
    # Create WireGuard directories
    ensure_directory "/etc/wireguard" "700"
    
    # Get peers directory from config
    local peers_dir
    peers_dir=$(get_config_value "vps.wireguard.peers_dir" "/etc/wireguard/peers")
    ensure_directory "$peers_dir" "700"
    
    # Create additional directories for organization
    ensure_directory "/etc/wireguard/keys" "700"
    ensure_directory "/etc/wireguard/configs" "700"
    
    log_success "WireGuard directories created"
}

setup_vps_keys() {
    log "Setting up VPS WireGuard keys..."
    
    # Get key paths from config
    local private_key_path
    private_key_path=$(get_config_value "vps.wireguard.private_key_path" "/etc/wireguard/vps-private.key")
    
    local public_key_path
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
    
    # Generate public key if it doesn't exist
    if [[ ! -f "$public_key_path" ]]; then
        log "Generating VPS public key..."
        local private_key
        private_key=$(cat "$private_key_path")
        generate_wg_public_key "$private_key" > "$public_key_path"
        chmod 644 "$public_key_path"
        log_success "VPS public key generated: $public_key_path"
    else
        log "VPS public key already exists: $public_key_path"
    fi
    
    # Display public key for reference
    local public_key
    public_key=$(cat "$public_key_path")
    log "VPS WireGuard public key: $public_key"
}

enable_wireguard_module() {
    log "Enabling WireGuard kernel module..."
    
    # Try to load the WireGuard module
    if ! lsmod | grep -q wireguard; then
        if modprobe wireguard 2>/dev/null; then
            log_success "WireGuard kernel module loaded"
        else
            log_warning "Could not load WireGuard kernel module (userspace fallback will be used)"
        fi
    else
        log "WireGuard kernel module already loaded"
    fi
    
    # Add to modules to load at boot
    if [[ ! -f /etc/modules-load.d/wireguard.conf ]]; then
        echo "wireguard" > /etc/modules-load.d/wireguard.conf
        log "Added WireGuard to boot-time modules"
    fi
    
    # Enable systemd-networkd if not enabled (some distros need this)
    if systemctl list-unit-files | grep -q systemd-networkd; then
        if ! systemctl is-enabled systemd-networkd &>/dev/null; then
            log "Enabling systemd-networkd for WireGuard support"
            systemctl enable systemd-networkd
        fi
    fi
}

# Run main function
main "$@"