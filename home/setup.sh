#!/bin/bash
# VPS Proxy Hub - Home Machine Setup Orchestrator
# Configures a home machine as a WireGuard peer to connect to the VPS gateway

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/../config.yaml}"
PEER_NAME=""

# Load shared utilities
source "$SCRIPT_DIR/../shared/utils.sh"

# Set logging prefix for this script
export LOG_PREFIX="[HOME-SETUP]"

# Display banner
show_banner() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                        VPS Proxy Hub - Home Setup                           ║
║                                                                              ║
║  Sets up a home machine as a WireGuard peer to connect to your VPS gateway. ║
║  Services running on this machine will be accessible through the VPS.       ║
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
    if [[ $# -eq 0 ]]; then
        log_error "Peer name is required"
        show_usage
        exit 1
    fi
    
    PEER_NAME="$1"
    shift
    
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
    
    # Validate peer name
    if ! validate_peer_name "$PEER_NAME"; then
        log_error "Peer '$PEER_NAME' not found in configuration"
        echo ""
        echo "Available peers:"
        show_available_peers
        exit 1
    fi
}

# Validate peer name exists in config
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

# Show available peers from config
show_available_peers() {
    if command -v yq &> /dev/null; then
        yq eval '.peers[] | "  - " + .name + " (" + .address + ")"' "$CONFIG_FILE"
    else
        grep -A 5 "^peers:" "$CONFIG_FILE" | grep -E "name:|address:" | paste - - | \
        sed 's/.*name: *["'\'']*/  - /' | sed 's/["'\'']*.* address: */ (/' | sed 's/[)\s]*$/))/' || \
        log "Check config.yaml for available peer names"
    fi
}

# Show usage information
show_usage() {
    echo "Usage: $0 <peer-name> [OPTIONS]"
    echo ""
    echo "Arguments:"
    echo "  peer-name            Name of the peer to configure (from config.yaml)"
    echo ""
    echo "Options:"
    echo "  --force              Force installation, overwrite existing configs"
    echo "  --skip-step STEP     Skip a specific setup step (1-3)"
    echo "  --help, -h           Show this help message"
    echo ""
    echo "Setup steps:"
    echo "  1. WireGuard installation"
    echo "  2. WireGuard peer configuration"
    echo "  3. Routing and network setup"
    echo ""
    echo "Examples:"
    echo "  $0 home-1                       # Setup peer 'home-1'"
    echo "  $0 home-2 --skip-step 1         # Setup peer 'home-2', skip WireGuard install"
    echo "  $0 home-1 --force               # Force setup, overwrite existing configs"
    echo ""
    echo "Available peers from config.yaml:"
    show_available_peers
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
    
    if "$script_path" "$PEER_NAME"; then
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
    log_success "Home machine setup completed for peer: $PEER_NAME"
    echo ""
    
    # Get peer configuration details
    local peer_address peer_endpoint
    if command -v yq &> /dev/null; then
        peer_address=$(yq eval ".peers[] | select(.name == \"$PEER_NAME\") | .address" "$CONFIG_FILE")
        peer_endpoint=$(yq eval ".peers[] | select(.name == \"$PEER_NAME\") | .endpoint" "$CONFIG_FILE")
    fi
    
    log "═══ Peer Configuration ═══"
    echo "Peer Name: $PEER_NAME"
    echo "Peer Address: ${peer_address:-Not available}"
    echo "VPS Endpoint: ${peer_endpoint:-Not available}"
    echo ""
    
    log "═══ Next Steps ═══"
    echo "1. The public key for this peer has been displayed above."
    echo "   Copy the command and run it on your VPS to complete the connection."
    echo ""
    echo "2. Verify the connection:"
    echo "   - Check WireGuard status: wg show wg0"
    echo "   - Test VPS connectivity: ping 10.8.0.1"
    echo "   - Check logs: journalctl -u wg-quick@wg0"
    echo ""
    
    echo "3. Start your services:"
    
    # Show service information for this peer
    if command -v yq &> /dev/null; then
        local has_sites=false
        while IFS= read -r site_name; do
            if [[ -n "$site_name" ]]; then
                local site_peer site_docker port container_name
                site_peer=$(yq eval ".sites[] | select(.name == \"$site_name\") | .peer" "$CONFIG_FILE")
                
                if [[ "$site_peer" == "$PEER_NAME" ]]; then
                    if [[ "$has_sites" == "false" ]]; then
                        echo "   Services configured for this peer:"
                        has_sites=true
                    fi
                    
                    site_docker=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.docker" "$CONFIG_FILE")
                    
                    if [[ "$site_docker" == "true" ]]; then
                        container_name=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.container_name" "$CONFIG_FILE")
                        echo "   - $site_name: Docker container '$container_name'"
                        echo "     Use: docker-${site_name}-run <image> [args...]"
                    else
                        port=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.port" "$CONFIG_FILE")
                        echo "   - $site_name: Service on port $port"
                        echo "     Ensure your service is running on localhost:$port"
                    fi
                fi
            fi
        done < <(yq eval '.sites[] | .name' "$CONFIG_FILE")
        
        if [[ "$has_sites" == "false" ]]; then
            echo "   No sites configured for peer '$PEER_NAME'"
        fi
    fi
    
    echo ""
    echo "4. Test your sites (after VPS setup is complete):"
    echo "   - Check the domains in your config.yaml"
    echo "   - Verify they're accessible through the VPS"
    echo ""
    
    log_warning "Remember to:"
    echo "• Complete the VPS setup by running the displayed command"
    echo "• Start your services on the configured ports"
    echo "• Check firewall settings if services aren't accessible"
    echo "• Monitor logs in /var/log/vps-proxy-hub-home.log"
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
    
    log "Setting up home machine as peer: $PEER_NAME"
    echo ""
    
    # Setup steps
    local setup_failed=false
    
    # Step 1: WireGuard installation
    if ! run_setup_script "1" "WireGuard Installation" "01-wireguard-install.sh"; then
        setup_failed=true
    fi
    
    # Step 2: WireGuard peer configuration
    if [[ "$setup_failed" == "false" ]]; then
        if ! run_setup_script "2" "WireGuard Peer Configuration" "02-wireguard-config.sh"; then
            setup_failed=true
        fi
    fi
    
    # Step 3: Routing and network setup
    if [[ "$setup_failed" == "false" ]]; then
        if ! run_setup_script "3" "Routing and Network Setup" "03-routing-setup.sh"; then
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