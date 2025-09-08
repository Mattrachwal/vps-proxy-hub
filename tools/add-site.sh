#!/bin/bash
# VPS Proxy Hub - Add New Site Tool
# Adds a new site/domain to peer mapping to the configuration and regenerates services

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/../config.yaml}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${BLUE}[ADD-SITE]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

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

# Check prerequisites
check_prerequisites() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Check if config file exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Install yq if not present
    if ! command -v yq &> /dev/null; then
        log "Installing yq for YAML manipulation..."
        if command -v snap &> /dev/null; then
            snap install yq
        elif command -v wget &> /dev/null; then
            YQ_VERSION="v4.35.2"
            YQ_BINARY="yq_linux_amd64"
            wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}"
            chmod +x /usr/local/bin/yq
        else
            log_error "Could not install yq. Please install manually."
            exit 1
        fi
    fi
}

# Show available peers
show_available_peers() {
    log "Available peers:"
    yq eval '.peers[] | "  - " + .name + " (" + .address + ")"' "$CONFIG_FILE"
}

# Validate peer exists
validate_peer() {
    local peer_name="$1"
    
    if yq eval ".peers[] | select(.name == \"$peer_name\") | .name" "$CONFIG_FILE" 2>/dev/null | grep -q "$peer_name"; then
        return 0
    else
        return 1
    fi
}

# Interactive mode
interactive_mode() {
    echo "═══ Interactive Site Addition ═══"
    echo ""
    
    # Site name
    read -p "Site name (internal reference): " SITE_NAME
    while [[ -z "$SITE_NAME" ]]; do
        echo "Site name cannot be empty."
        read -p "Site name (internal reference): " SITE_NAME
    done
    
    # Check if site name already exists
    if yq eval ".sites[] | select(.name == \"$SITE_NAME\") | .name" "$CONFIG_FILE" 2>/dev/null | grep -q "$SITE_NAME"; then
        log_error "Site '$SITE_NAME' already exists in configuration"
        exit 1
    fi
    
    # Domains
    echo ""
    echo "Enter domains (comma-separated, e.g., 'site.com,www.site.com'):"
    read -p "Domains: " DOMAINS_INPUT
    while [[ -z "$DOMAINS_INPUT" ]]; do
        echo "At least one domain is required."
        read -p "Domains: " DOMAINS_INPUT
    done
    
    # Convert comma-separated domains to array
    IFS=',' read -ra DOMAINS_ARRAY <<< "$DOMAINS_INPUT"
    DOMAINS=()
    for domain in "${DOMAINS_ARRAY[@]}"; do
        # Trim whitespace
        domain=$(echo "$domain" | xargs)
        if [[ -n "$domain" ]]; then
            DOMAINS+=("$domain")
        fi
    done
    
    # Peer selection
    echo ""
    show_available_peers
    echo ""
    read -p "Peer name: " PEER_NAME
    while [[ -z "$PEER_NAME" ]] || ! validate_peer "$PEER_NAME"; do
        echo "Invalid peer name. Please select from the available peers above."
        read -p "Peer name: " PEER_NAME
    done
    
    # Service type
    echo ""
    echo "Service type:"
    echo "1. Direct port (service running on peer machine)"
    echo "2. Docker container (service running in Docker)"
    read -p "Select option (1 or 2): " SERVICE_TYPE
    
    IS_DOCKER=false
    case "$SERVICE_TYPE" in
        1)
            # Direct port
            echo ""
            read -p "Service port: " SERVICE_PORT
            while [[ ! "$SERVICE_PORT" =~ ^[0-9]+$ ]] || [[ "$SERVICE_PORT" -lt 1 ]] || [[ "$SERVICE_PORT" -gt 65535 ]]; do
                echo "Invalid port number. Please enter a number between 1 and 65535."
                read -p "Service port: " SERVICE_PORT
            done
            ;;
        2)
            # Docker container
            IS_DOCKER=true
            echo ""
            read -p "Container name: " CONTAINER_NAME
            while [[ -z "$CONTAINER_NAME" ]]; do
                echo "Container name cannot be empty."
                read -p "Container name: " CONTAINER_NAME
            done
            
            read -p "Container port: " CONTAINER_PORT
            while [[ ! "$CONTAINER_PORT" =~ ^[0-9]+$ ]] || [[ "$CONTAINER_PORT" -lt 1 ]] || [[ "$CONTAINER_PORT" -gt 65535 ]]; do
                echo "Invalid port number. Please enter a number between 1 and 65535."
                read -p "Container port: " CONTAINER_PORT
            done
            ;;
        *)
            log_error "Invalid selection"
            exit 1
            ;;
    esac
    
    # Confirmation
    echo ""
    echo "═══ Site Configuration Summary ═══"
    echo "Site Name: $SITE_NAME"
    echo "Domains: ${DOMAINS[*]}"
    echo "Peer: $PEER_NAME"
    if [[ "$IS_DOCKER" == "true" ]]; then
        echo "Type: Docker container"
        echo "Container: $CONTAINER_NAME"
        echo "Port: $CONTAINER_PORT"
    else
        echo "Type: Direct port"
        echo "Port: $SERVICE_PORT"
    fi
    echo ""
    
    read -p "Add this site? (y/N): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
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

# Validate arguments
validate_arguments() {
    if [[ "$INTERACTIVE" == "true" ]]; then
        return 0
    fi
    
    # Required arguments
    if [[ -z "$SITE_NAME" ]]; then
        log_error "--site-name is required"
        exit 1
    fi
    
    if [[ ${#DOMAINS[@]} -eq 0 ]]; then
        log_error "--domains is required"
        exit 1
    fi
    
    if [[ -z "$PEER_NAME" ]]; then
        log_error "--peer is required"
        exit 1
    fi
    
    # Validate peer exists
    if ! validate_peer "$PEER_NAME"; then
        log_error "Peer '$PEER_NAME' not found in configuration"
        echo ""
        show_available_peers
        exit 1
    fi
    
    # Check if site name already exists
    if yq eval ".sites[] | select(.name == \"$SITE_NAME\") | .name" "$CONFIG_FILE" 2>/dev/null | grep -q "$SITE_NAME"; then
        log_error "Site '$SITE_NAME' already exists in configuration"
        exit 1
    fi
    
    # Service configuration validation
    if [[ "$IS_DOCKER" == "true" ]]; then
        if [[ -z "$CONTAINER_NAME" ]]; then
            log_error "--container is required when using --docker"
            exit 1
        fi
        if [[ -z "$CONTAINER_PORT" ]]; then
            log_error "--container-port is required when using --docker"
            exit 1
        fi
    else
        if [[ -z "$SERVICE_PORT" ]]; then
            log_error "--port is required when not using --docker"
            exit 1
        fi
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