#!/bin/bash
# Home Machine Setup - WireGuard Installation
# Installs WireGuard and resolvconf (or handles DNS= gracefully)

set -euo pipefail

# Load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../shared/utils.sh"
source "$SCRIPT_DIR/../../shared/wireguard_utils.sh"

main() {
    log "Starting WireGuard installation on home machine..."
    
    check_root
    check_config
    install_yq
    
    # Install WireGuard based on the distribution
    install_wireguard
    
    # Install resolvconf or handle DNS= lines gracefully
    install_resolvconf
    
    # Create WireGuard directory structure
    setup_wireguard_directories "home"
    
    # Enable WireGuard kernel module
    enable_wireguard_module
    
    log_success "WireGuard installation completed"
}

# Run main function
main "$@"