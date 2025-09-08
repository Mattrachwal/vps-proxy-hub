#!/bin/bash
# VPS Proxy Hub - Main VPS Setup Orchestrator
# Runs all VPS setup scripts in the correct order

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/../config.yaml}"

# Load shared utilities
source "$SCRIPT_DIR/../shared/utils.sh"

# Set logging prefix for this script
export LOG_PREFIX="[SETUP]"

# Display banner
show_banner() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                           VPS Proxy Hub Setup                               ║
║                                                                              ║
║  Sets up a VPS as an edge gateway with WireGuard tunnels and Nginx proxy    ║
║  for accessing home lab services through encrypted tunnels.                 ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
}

# Check prerequisites using shared utilities
check_prerequisites() {
    log "Checking prerequisites..."
    check_root
    check_config
    install_yq
    log_success "Prerequisites check passed"
}

# Parse command line arguments
parse_arguments() {
    FORCE_INSTALL=false
    SKIP_STEPS=()
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                FORCE_INSTALL=true
                log_warning "Force installation enabled - will overwrite existing configurations"
                shift
                ;;
            --skip-step)
                if [[ -n "${2:-}" ]]; then
                    SKIP_STEPS+=("$2")
                    log_warning "Will skip step: $2"
                    shift 2
                else
                    log_error "--skip-step requires a step number"
                    exit 1
                fi
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Show usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --force              Force installation, overwrite existing configs"
    echo "  --skip-step STEP     Skip a specific setup step (1-6)"
    echo "  --help, -h           Show this help message"
    echo ""
    echo "Setup steps:"
    echo "  1. System update and configuration"
    echo "  2. UFW firewall setup"
    echo "  3. WireGuard installation"
    echo "  4. WireGuard configuration"
    echo "  5. Nginx installation and configuration"
    echo "  6. Nginx virtual hosts and SSL certificates"
    echo ""
    echo "Examples:"
    echo "  $0                          # Full setup"
    echo "  $0 --skip-step 1            # Skip system update"
    echo "  $0 --force --skip-step 2    # Force install, skip firewall"
}

# Check if step should be skipped
should_skip_step() {
    local step="$1"
    for skip_step in "${SKIP_STEPS[@]}"; do
        if [[ "$skip_step" == "$step" ]]; then
            return 0
        fi
    done
    return 1
}

# Run a setup script with error handling
run_setup_script() {
    local step_num="$1"
    local step_name="$2"
    local script_name="$3"
    local script_path="$SCRIPT_DIR/scripts/$script_name"
    
    if should_skip_step "$step_num"; then
        log_warning "Skipping step $step_num: $step_name"
        return 0
    fi
    
    log "═══ Step $step_num: $step_name ═══"
    
    if [[ ! -f "$script_path" ]]; then
        log_error "Setup script not found: $script_path"
        return 1
    fi
    
    if [[ ! -x "$script_path" ]]; then
        chmod +x "$script_path"
    fi
    
    # Export configuration for the script
    export CONFIG_FILE
    export FORCE_INSTALL
    
    # Run the script with error handling
    local start_time=$(date +%s)
    
    if "$script_path"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_success "Step $step_num completed successfully in ${duration}s"
        echo ""
        return 0
    else
        log_error "Step $step_num failed: $step_name"
        return 1
    fi
}

# Display completion information
show_completion_info() {
    log_success "VPS setup completed successfully!"
    echo ""
    
    # Show connection information
    log "═══ Connection Information ═══"
    
    # Extract VPS public key and connection details
    local public_key_path="/etc/wireguard/vps-public.key"
    local public_ip listen_port
    
    if command -v yq &> /dev/null; then
        public_ip=$(yq eval '.vps.public_ip' "$CONFIG_FILE")
        listen_port=$(yq eval '.vps.wireguard.listen_port' "$CONFIG_FILE")
    else
        public_ip=$(grep "public_ip:" "$CONFIG_FILE" | head -1 | sed 's/.*: *["'\'']*//' | sed 's/["'\'']*.*//')
        listen_port=$(grep "listen_port:" "$CONFIG_FILE" | head -1 | sed 's/.*: *//')
    fi
    
    if [[ -f "$public_key_path" ]]; then
        local vps_public_key
        vps_public_key=$(cat "$public_key_path")
        
        echo "VPS WireGuard Public Key: $vps_public_key"
        echo "VPS Endpoint: $public_ip:$listen_port"
    fi
    
    echo ""
    log "═══ Next Steps ═══"
    echo "1. Set up home machines:"
    echo "   - Copy this repository to each home machine"
    echo "   - Run: sudo ./home/setup.sh <peer-name>"
    echo "   - Add the generated public key to VPS using: ./toos/add-peer-key.sh <peer-name> '<public-key>'"
    echo ""
    
    echo "2. Verify WireGuard connections:"
    echo "   - Check status: wg show wg0"
    echo "   - Check logs: journalctl -u wg-quick@wg0"
    echo ""
    
    echo "3. Test your sites:"
    if command -v yq &> /dev/null; then
        yq eval '.sites[] | .server_names[]' "$CONFIG_FILE" | head -3 | while IFS= read -r domain; do
            echo "   - https://$domain"
        done
    else
        log "   - Check the domains configured in your config.yaml"
    fi
    echo ""
    
    echo "4. Management commands:"
    echo "   - Add new site: ./tools/add-site.sh"
    echo "   - Check status: ./tools/status.sh"
    echo "   - View logs: tail -f /var/log/vps-proxy-hub.log"
    echo ""
    
    log_warning "Remember to:"
    echo "• Ensure your domains point to this VPS IP: $public_ip"
    echo "• Open firewall ports 80, 443, and $listen_port if using external firewall"
    echo "• Set up DNS records before testing SSL certificates"
    echo "• Monitor the setup logs in /var/log/vps-proxy-hub.log"
}

# Main setup function
main() {
    local start_time=$(date +%s)
    
    # Show banner
    show_banner
    echo ""
    
    # Parse arguments
    parse_arguments "$@"
    
    # Check prerequisites
    check_prerequisites
    
    # Setup steps
    local setup_failed=false
    
    # Step 1: System update and configuration
    if ! run_setup_script "1" "System Update and Configuration" "01-system-update.sh"; then
        setup_failed=true
    fi
    
    # Step 2: UFW firewall setup
    if [[ "$setup_failed" == "false" ]]; then
        if ! run_setup_script "2" "UFW Firewall Setup" "02-ufw-setup.sh"; then
            setup_failed=true
        fi
    fi
    
    # Step 3: WireGuard installation
    if [[ "$setup_failed" == "false" ]]; then
        if ! run_setup_script "3" "WireGuard Installation" "03-wireguard-install.sh"; then
            setup_failed=true
        fi
    fi
    
    # Step 4: WireGuard configuration
    if [[ "$setup_failed" == "false" ]]; then
        if ! run_setup_script "4" "WireGuard Configuration" "04-wireguard-config.sh"; then
            setup_failed=true
        fi
    fi
    
    # Step 5: Nginx installation and configuration
    if [[ "$setup_failed" == "false" ]]; then
        if ! run_setup_script "5" "Nginx Installation and Configuration" "05-nginx-install.sh"; then
            setup_failed=true
        fi
    fi
    
    # Step 6: Nginx virtual hosts and SSL certificates
    if [[ "$setup_failed" == "false" ]]; then
        if ! run_setup_script "6" "Nginx Virtual Hosts and SSL" "06-nginx-vhosts.sh"; then
            setup_failed=true
        fi
    fi
    
    # Show results
    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))
    
    echo ""
    if [[ "$setup_failed" == "true" ]]; then
        log_error "Setup failed! Check the logs above for details."
        echo "Total time: ${total_duration}s"
        exit 1
    else
        show_completion_info
        echo "Total setup time: ${total_duration}s"
    fi
}

# Run main function with all arguments
main "$@"