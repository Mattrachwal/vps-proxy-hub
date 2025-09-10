#!/bin/bash
# VPS Proxy Hub - Remove Site Tool
# Removes a site/domain mapping from the configuration and cleans up services

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/../config.yaml}"

# Load shared utilities (includes colors and logging functions)
source "$SCRIPT_DIR/../shared/utils.sh"

# Set logging prefix for this script
export LOG_PREFIX="[REMOVE-SITE]"

# Show usage information
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] <site-name>

Remove a site/domain mapping from the VPS Proxy Hub configuration.

Arguments:
  site-name            Name of the site to remove

Options:
  --force, -f          Skip confirmation prompt
  --keep-certs         Keep SSL certificates (don't revoke)
  --help, -h           Show this help message

Examples:
  $0 blog                    # Remove site 'blog' (with confirmation)
  $0 --force media          # Remove site 'media' without confirmation
  $0 --keep-certs wiki      # Remove site but keep SSL certificates

This will:
- Remove the site from config.yaml
- Remove Nginx virtual host configuration
- Revoke SSL certificates (unless --keep-certs is used)
- Clean up related files
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

# Show available sites
show_available_sites() {
    log "Available sites:"
    if ! yq eval '.sites[] | "  - " + .name + " (" + (.server_names | join(", ")) + ")"' "$CONFIG_FILE" 2>/dev/null; then
        log "No sites found in configuration"
    fi
}

# Get site information
get_site_info() {
    local site_name="$1"
    
    # Get site configuration
    SITE_CONFIG=$(yq eval ".sites[] | select(.name == \"$site_name\")" "$CONFIG_FILE" 2>/dev/null)
    
    if [[ -z "$SITE_CONFIG" || "$SITE_CONFIG" == "null" ]]; then
        return 1
    fi
    
    # Extract site details
    SITE_DOMAINS=($(yq eval ".sites[] | select(.name == \"$site_name\") | .server_names[]" "$CONFIG_FILE" 2>/dev/null))
    SITE_PEER=$(yq eval ".sites[] | select(.name == \"$site_name\") | .peer" "$CONFIG_FILE" 2>/dev/null)
    SITE_IS_DOCKER=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.docker" "$CONFIG_FILE" 2>/dev/null)
    
    return 0
}

# Parse command line arguments
parse_arguments() {
    SITE_NAME=""
    FORCE_REMOVE=false
    KEEP_CERTS=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force|-f)
                FORCE_REMOVE=true
                shift
                ;;
            --keep-certs)
                KEEP_CERTS=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [[ -z "$SITE_NAME" ]]; then
                    SITE_NAME="$1"
                else
                    log_error "Too many arguments"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # Validate required arguments
    if [[ -z "$SITE_NAME" ]]; then
        log_error "Site name is required"
        echo ""
        show_available_sites
        echo ""
        show_usage
        exit 1
    fi
}

# Confirm removal
confirm_removal() {
    if [[ "$FORCE_REMOVE" == "true" ]]; then
        return 0
    fi
    
    echo "═══ Site Removal Confirmation ═══"
    echo "Site Name: $SITE_NAME"
    echo "Domains: ${SITE_DOMAINS[*]}"
    echo "Peer: $SITE_PEER"
    echo "Type: $([[ "$SITE_IS_DOCKER" == "true" ]] && echo "Docker" || echo "Direct")"
    echo ""
    
    log_warning "This will:"
    echo "• Remove the site from configuration"
    echo "• Remove Nginx virtual host"
    if [[ "$KEEP_CERTS" == "false" ]]; then
        echo "• Revoke SSL certificates"
    else
        echo "• Keep SSL certificates (--keep-certs specified)"
    fi
    echo "• Clean up related files"
    echo ""
    
    read -p "Are you sure you want to remove this site? (y/N): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        log "Site removal cancelled"
        exit 0
    fi
}

# Remove SSL certificates
remove_ssl_certificates() {
    if [[ "$KEEP_CERTS" == "true" ]]; then
        log "Keeping SSL certificates as requested"
        return 0
    fi
    
    log "Removing SSL certificates for site: $SITE_NAME"
    
    # Check if certbot is available
    if ! command -v certbot &> /dev/null; then
        log_warning "Certbot not found, skipping certificate removal"
        return 0
    fi
    
    # Remove certificates for each domain
    for domain in "${SITE_DOMAINS[@]}"; do
        if certbot certificates 2>/dev/null | grep -q "$domain"; then
            log "Revoking certificate for $domain..."
            if certbot revoke --cert-name "$domain" --delete-after-revoke --non-interactive; then
                log_success "Certificate revoked for $domain"
            else
                log_warning "Failed to revoke certificate for $domain"
            fi
        else
            log "No certificate found for $domain"
        fi
    done
}

# Remove Nginx configuration
remove_nginx_config() {
    log "Removing Nginx configuration for site: $SITE_NAME"
    
    # Match the actual file naming pattern used by 06-nginx-vhosts.sh
    local vhost_available="/etc/nginx/sites-available/vps-proxy-hub-${SITE_NAME}.conf"
    local vhost_enabled="/etc/nginx/sites-enabled/vps-proxy-hub-${SITE_NAME}.conf"
    
    # Remove symbolic link
    if [[ -L "$vhost_enabled" ]]; then
        rm -f "$vhost_enabled"
        log "Removed Nginx site link: $vhost_enabled"
    fi
    
    # Remove configuration file
    if [[ -f "$vhost_available" ]]; then
        rm -f "$vhost_available"
        log "Removed Nginx site config: $vhost_available"
    fi
    
    # Test and reload Nginx
    if command -v nginx &> /dev/null; then
        if nginx -t 2>/dev/null; then
            if systemctl reload nginx; then
                log_success "Nginx configuration reloaded"
            else
                log_warning "Failed to reload Nginx"
            fi
        else
            log_warning "Nginx configuration test failed"
        fi
    fi
}

# Remove site from configuration
remove_site_from_config() {
    log "Removing site '$SITE_NAME' from configuration..."
    
    # Create backup of config file
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Remove the site from configuration
    yq eval "del(.sites[] | select(.name == \"$SITE_NAME\"))" -i "$CONFIG_FILE"
    
    log_success "Site '$SITE_NAME' removed from configuration"
}

# Clean up related files
cleanup_related_files() {
    log "Cleaning up related files for site: $SITE_NAME"
    
    # Remove any log files
    local log_files=(
        "/var/log/nginx/${SITE_NAME}_access.log"
        "/var/log/nginx/${SITE_NAME}_error.log"
    )
    
    for log_file in "${log_files[@]}"; do
        if [[ -f "$log_file" ]]; then
            rm -f "$log_file"
            log "Removed log file: $log_file"
        fi
    done
    
    # Remove any Docker helper scripts
    local docker_script="/usr/local/bin/docker-${SITE_NAME}-run"
    if [[ -f "$docker_script" ]]; then
        rm -f "$docker_script"
        log "Removed Docker helper script: $docker_script"
    fi
    
    # Clean up any temporary files
    rm -f "/tmp/vps-proxy-hub-${SITE_NAME}"*
}

# Display completion information
show_completion_info() {
    log_success "Site '$SITE_NAME' has been removed successfully!"
    echo ""
    
    log "═══ Cleanup Summary ═══"
    echo "✓ Removed from configuration"
    echo "✓ Nginx virtual host removed"
    if [[ "$KEEP_CERTS" == "false" ]]; then
        echo "✓ SSL certificates revoked"
    else
        echo "• SSL certificates kept"
    fi
    echo "✓ Related files cleaned up"
    echo ""
    
    log "═══ Next Steps ═══"
    echo "1. The following domains are no longer served:"
    for domain in "${SITE_DOMAINS[@]}"; do
        echo "   - $domain"
    done
    echo ""
    
    if [[ "$SITE_IS_DOCKER" == "true" ]]; then
        echo "2. You may want to stop/remove the Docker container on peer '$SITE_PEER'"
        echo "   - docker stop <container-name>"
        echo "   - docker rm <container-name>"
    else
        echo "2. You may want to stop the service on peer '$SITE_PEER'"
    fi
    echo ""
    
    echo "3. Update DNS records if domains will not be used elsewhere"
    echo ""
    
    log_warning "Configuration backup saved to: ${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
}

# Main function
main() {
    log "VPS Proxy Hub - Remove Site Tool"
    echo ""
    
    # Parse arguments
    parse_arguments "$@"
    
    # Check prerequisites
    check_prerequisites
    
    # Get site information
    if ! get_site_info "$SITE_NAME"; then
        log_error "Site '$SITE_NAME' not found in configuration"
        echo ""
        show_available_sites
        exit 1
    fi
    
    # Confirm removal
    confirm_removal
    
    # Remove SSL certificates first (before removing config)
    remove_ssl_certificates
    
    # Remove Nginx configuration
    remove_nginx_config
    
    # Remove site from configuration
    remove_site_from_config
    
    # Clean up related files
    cleanup_related_files
    
    # Show completion information
    show_completion_info
}

# Run main function with all arguments
main "$@"