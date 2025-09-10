#!/bin/bash
# VPS Setup - WireGuard Installation
# Installs WireGuard and sets up the basic configuration structure

set -euo pipefail

# Load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../shared/utils.sh"
source "$SCRIPT_DIR/../../shared/wireguard_utils.sh"

main() {
    log "Starting WireGuard installation..."
    
    check_root
    check_config
    
    # Install WireGuard based on the distribution
    install_wireguard
    
    # Create WireGuard directory structure
    setup_wireguard_directories "vps"
    
    # Generate VPS keys if they don't exist
    setup_vps_keys
    
    # Enable WireGuard kernel module
    enable_wireguard_module
    
    log_success "WireGuard installation completed"
}

# Run main function
main "$@"