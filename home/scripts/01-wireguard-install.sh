#!/bin/bash
# Home Machine Setup - WireGuard Installation
# Installs WireGuard and prepares the environment for peer configuration

set -euo pipefail

# Load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

main() {
    log "Starting WireGuard installation on home machine..."
    
    check_root
    check_config
    install_yq
    
    # Install WireGuard based on the distribution
    install_wireguard
    
    # Create WireGuard directory structure
    setup_wireguard_directories
    
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
    
    # Create additional directories for organization
    ensure_directory "/etc/wireguard/keys" "700"
    ensure_directory "/etc/wireguard/backup" "700"
    
    log_success "WireGuard directories created"
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