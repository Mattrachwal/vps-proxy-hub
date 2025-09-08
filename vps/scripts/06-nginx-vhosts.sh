#!/bin/bash
# VPS Setup - Nginx Virtual Hosts Configuration
# Generates Nginx virtual hosts from config.yaml with proper HTTP+HTTPS setup
# 
# This script has been refactored to use modular utilities for better maintainability.
# Main responsibilities:
#   - Coordinate site processing workflow
#   - Handle error cases and rollback scenarios  
#   - Provide high-level logging and status reporting

set -euo pipefail

# Load shared utilities for common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../shared/utils.sh"
source "$SCRIPT_DIR/../../shared/nginx_utils.sh"

# Set logging prefix for this script
export LOG_PREFIX="[NGINX-VHOSTS]"

# Main workflow coordination function
# Orchestrates the complete nginx virtual host setup process
main() {
    log "Starting Nginx virtual hosts configuration..."

    # Validate prerequisites
    check_root
    check_config
    
    # Install yq if needed for better YAML parsing
    install_yq

    # Ensure ACME challenge directory exists for Let's Encrypt
    ensure_directory "/var/www/html" "755"

    # Step 1: Process all sites and generate virtual host configurations
    if ! process_all_sites; then
        log_error "Failed to process sites - aborting nginx configuration"
        return 1
    fi

    # Step 2: Validate generated nginx configuration syntax
    if ! test_nginx_configuration; then
        log_error "Nginx configuration test failed - aborting to prevent service disruption"
        return 1
    fi

    # Step 3: Apply configuration changes by reloading nginx
    if ! reload_nginx_configuration; then
        log_error "Failed to reload nginx - configuration may be invalid"
        return 1
    fi

    # Step 4: Obtain and install SSL certificates
    # Note: This step can partially fail without breaking the overall setup
    if ! obtain_all_ssl_certificates; then
        log_warning "SSL certificate setup encountered issues, but basic HTTP setup is complete"
        log "You can run SSL setup manually later: certbot --nginx"
        log "Or re-run this script once DNS is properly configured"
    fi

    log_success "Nginx virtual hosts configuration completed successfully"
}

# =============================================================================
# LEGACY COMPATIBILITY FUNCTIONS
# These functions maintain backward compatibility with existing scripts
# while redirecting to the new modular implementations
# =============================================================================

# Legacy function - redirect to new modular implementation
# This maintains backward compatibility while using the new utilities
process_sites() {
    # Use the new modular function from nginx_utils.sh
    process_all_sites
}

# Legacy function - redirect to new modular implementation  
process_site() {
    local site_name="$1"
    # Use the new modular function from nginx_utils.sh
    process_single_site "$site_name"
}

# Legacy function - redirect to new modular implementation
test_nginx_config() {
    # Use the new modular function from nginx_utils.sh
    test_nginx_configuration
}

# Legacy function - redirect to new modular implementation
reload_nginx() {
    # Use the new modular function from nginx_utils.sh
    reload_nginx_configuration
}

# Legacy function - redirect to new modular implementation
obtain_ssl_certificates() {
    # Use the new modular function from nginx_utils.sh
    obtain_all_ssl_certificates
}

# Legacy function - redirect to new modular implementation
obtain_site_ssl() {
    local site_name="$1" 
    local email="$2" 
    local staging_flag="$3"
    # Use the new modular function from nginx_utils.sh
    obtain_site_ssl_certificate "$site_name" "$email" "$staging_flag"
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

# Run main function with all command line arguments
main "$@"