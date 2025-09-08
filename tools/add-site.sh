#!/bin/bash
# VPS Proxy Hub - Add New Site Tool
# Adds a new site/domain to peer mapping to the configuration and regenerates services
#
# This script provides both interactive and command-line modes for adding new sites
# to the VPS Proxy Hub configuration. It automatically updates nginx configurations.

set -euo pipefail

# Load shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../shared/utils.sh"
source "$SCRIPT_DIR/../shared/interactive_utils.sh"

# Set logging prefix for this script
export LOG_PREFIX="[ADD-SITE]"

# Show usage information
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Add a new site/domain to the VPS Proxy Hub configuration.

Options:
  --interactive, -i    Interactive mode (prompts for all values)
  --site-name NAME     Site name (used for internal reference)
  --domains DOMAINS    Comma-separated list of domains (e.g., "site.com,www.site.com")
  --peer PEER          Peer name from config.yaml
  --port PORT          Service port on the peer
  --docker             Service is a Docker container
  --container NAME     Docker container name (if --docker is used)
  --container-port PORT Docker container port (if --docker is used)
  --help, -h           Show this help message

Examples:
  $0 --interactive
  $0 --site-name blog --domains "blog.example.com" --peer home-1 --port 8080
  $0 --site-name media --domains "media.example.com" --peer home-2 --docker --container jellyfin --container-port 8096

Interactive mode will prompt for all required information.
EOF
}

# Check prerequisites using shared utility functions
check_prerequisites() {
    # Use shared utility functions for common checks
    check_root
    check_config
    install_yq
}

# Show available peers
show_available_peers() {
    log "Available peers:"
    yq eval '.peers[] | "  - " + .name + " (" + .address + ")"' "$CONFIG_FILE"
}

# Validate peer exists using shared utility function
validate_peer() {
    local peer_name="$1"
    validate_peer_name "$peer_name"
}

# Interactive mode using modular utility functions
# Guides user through site configuration with validation
interactive_mode() {
    echo "═══ Interactive Site Addition ═══"
    echo ""
    
    # Get site name and check if it already exists
    prompt_required_string "Site name (internal reference)" SITE_NAME
    if check_site_exists "$SITE_NAME"; then
        log_error "Site '$SITE_NAME' already exists in configuration"
        exit 1
    fi
    
    # Get domains list
    echo ""
    prompt_domains_list DOMAINS
    
    # Get peer selection
    prompt_peer_selection PEER_NAME
    
    # Get service type configuration
    prompt_service_type IS_DOCKER SERVICE_PORT CONTAINER_NAME CONTAINER_PORT
    
    # Show configuration summary and get confirmation
    show_configuration_summary "$SITE_NAME" DOMAINS "$PEER_NAME" "$IS_DOCKER" "$SERVICE_PORT" "$CONTAINER_NAME" "$CONTAINER_PORT"
    
    if ! get_confirmation "Add this site?"; then
        log "Site addition cancelled"
        exit 0
    fi
}

# Parse command line arguments
parse_arguments() {
    INTERACTIVE=false
    SITE_NAME=""
    DOMAINS=()
    PEER_NAME=""
    IS_DOCKER=false
    SERVICE_PORT=""
    CONTAINER_NAME=""
    CONTAINER_PORT=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --interactive|-i)
                INTERACTIVE=true
                shift
                ;;
            --site-name)
                SITE_NAME="$2"
                shift 2
                ;;
            --domains)
                IFS=',' read -ra DOMAINS_ARRAY <<< "$2"
                DOMAINS=()
                for domain in "${DOMAINS_ARRAY[@]}"; do
                    domain=$(echo "$domain" | xargs)
                    if [[ -n "$domain" ]]; then
                        DOMAINS+=("$domain")
                    fi
                done
                shift 2
                ;;
            --peer)
                PEER_NAME="$2"
                shift 2
                ;;
            --port)
                SERVICE_PORT="$2"
                shift 2
                ;;
            --docker)
                IS_DOCKER=true
                shift
                ;;
            --container)
                CONTAINER_NAME="$2"
                shift 2
                ;;
            --container-port)
                CONTAINER_PORT="$2"
                shift 2
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

# Validate arguments using shared utility functions
validate_arguments() {
    if [[ "$INTERACTIVE" == "true" ]]; then
        return 0
    fi
    
    # Use shared validation function
    if ! validate_site_arguments "$SITE_NAME" DOMAINS "$PEER_NAME" "$IS_DOCKER" "$SERVICE_PORT" "$CONTAINER_NAME" "$CONTAINER_PORT"; then
        exit 1
    fi
}

# Add site to configuration
add_site_to_config() {
    log "Adding site '$SITE_NAME' to configuration..."
    
    # Create backup of config file
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Build the new site configuration
    local site_config="{"
    site_config+="\"name\": \"$SITE_NAME\", "
    
    # Add server names
    site_config+="\"server_names\": ["
    for i in "${!DOMAINS[@]}"; do
        site_config+="\"${DOMAINS[i]}\""
        if [[ $i -lt $((${#DOMAINS[@]} - 1)) ]]; then
            site_config+=", "
        fi
    done
    site_config+="], "
    
    site_config+="\"peer\": \"$PEER_NAME\", "
    
    # Add upstream configuration
    site_config+="\"upstream\": {"
    if [[ "$IS_DOCKER" == "true" ]]; then
        site_config+="\"docker\": true, "
        site_config+="\"container_name\": \"$CONTAINER_NAME\", "
        site_config+="\"container_port\": $CONTAINER_PORT"
    else
        site_config+="\"docker\": false, "
        site_config+="\"port\": $SERVICE_PORT"
    fi
    site_config+="}, "
    
    # Add nginx configuration
    site_config+="\"nginx\": {"
    site_config+="\"force_https_redirect\": true, "
    site_config+="\"extra_headers\": {"
    site_config+="\"Strict-Transport-Security\": \"max-age=15552000; includeSubDomains; preload\", "
    site_config+="\"X-Content-Type-Options\": \"nosniff\", "
    site_config+="\"X-Frame-Options\": \"SAMEORIGIN\", "
    site_config+="\"Referrer-Policy\": \"strict-origin-when-cross-origin\""
    site_config+="}"
    site_config+="}"
    site_config+="}"
    
    # Add the site to the configuration
    yq eval ".sites += [$site_config]" -i "$CONFIG_FILE"
    
    log_success "Site '$SITE_NAME' added to configuration"
}

# Update VPS services by regenerating nginx virtual hosts
update_vps_services() {
    log "Updating VPS services..."
    
    # Check if VPS scripts are available
    local vps_scripts_dir="$SCRIPT_DIR/../vps/scripts"
    
    if [[ -d "$vps_scripts_dir" ]]; then
        log "Regenerating Nginx virtual hosts..."
        
        if [[ -x "$vps_scripts_dir/06-nginx-vhosts.sh" ]]; then
            # Export CONFIG_FILE for the script
            export CONFIG_FILE
            if "$vps_scripts_dir/06-nginx-vhosts.sh"; then
                log_success "Nginx virtual hosts updated"
            else
                log_error "Failed to update Nginx virtual hosts"
                return 1
            fi
        else
            log_warning "VPS nginx vhosts script not executable: $vps_scripts_dir/06-nginx-vhosts.sh"
        fi
    else
        log_warning "VPS scripts not found. You'll need to regenerate Nginx configuration manually."
        log "Run on VPS: ./vps/scripts/06-nginx-vhosts.sh"
    fi
}

# Display completion information
show_completion_info() {
    log_success "Site '$SITE_NAME' has been added successfully!"
    echo ""
    
    log "═══ Site Information ═══"
    echo "Site Name: $SITE_NAME"
    echo "Domains: ${DOMAINS[*]}"
    echo "Peer: $PEER_NAME"
    if [[ "$IS_DOCKER" == "true" ]]; then
        echo "Service: Docker container '$CONTAINER_NAME' on port $CONTAINER_PORT"
    else
        echo "Service: Direct port $SERVICE_PORT"
    fi
    echo ""
    
    log "═══ Next Steps ═══"
    echo "1. Ensure your service is running on the peer machine:"
    if [[ "$IS_DOCKER" == "true" ]]; then
        echo "   - Start Docker container: docker-${SITE_NAME}-run <image> [args...]"
        echo "   - Or manually: docker run --name $CONTAINER_NAME --network ${SITE_NAME}_net <image>"
    else
        echo "   - Start service on peer '$PEER_NAME' listening on port $SERVICE_PORT"
    fi
    echo ""
    
    echo "2. Verify DNS records point to your VPS:"
    for domain in "${DOMAINS[@]}"; do
        echo "   - $domain → VPS IP"
    done
    echo ""
    
    echo "3. Test the site:"
    for domain in "${DOMAINS[@]}"; do
        echo "   - https://$domain"
    done
    echo ""
    
    log_warning "SSL certificates will be obtained automatically when the domains are accessible"
}

# Main function
main() {
    log "VPS Proxy Hub - Add Site Tool"
    echo ""
    
    # Parse arguments
    parse_arguments "$@"
    
    # Check prerequisites
    check_prerequisites
    
    # Interactive mode or validate arguments
    if [[ "$INTERACTIVE" == "true" ]]; then
        interactive_mode
    else
        validate_arguments
    fi
    
    # Add site to configuration
    add_site_to_config
    
    # Update VPS services
    update_vps_services
    
    # Show completion information
    show_completion_info
}

# Run main function with all arguments
main "$@"