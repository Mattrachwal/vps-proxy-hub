#!/bin/bash
# VPS Setup - Nginx Virtual Hosts Configuration (FIXED)
# Generates Nginx virtual hosts from config.yaml with proper HTTP+HTTPS setup

set -euo pipefail

# Load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

main() {
    log "Starting Nginx virtual hosts configuration..."

    check_root
    check_config

    # Ensure ACME webroot exists
    ensure_directory "/var/www/html" "755"

    # Process each site in the configuration
    process_sites

    # Test nginx configuration
    test_nginx_config

    # Reload nginx to apply sites
    reload_nginx

    # Obtain SSL certificates and enable HTTPS
    obtain_ssl_certificates

    log_success "Nginx virtual hosts configuration completed"
}

# Process all sites from configuration
process_sites() {
    log "Processing sites from configuration..."

    # Remove existing VPS Proxy Hub vhosts (clean slate approach)
    log "Removing existing VPS Proxy Hub virtual host configurations..."
    rm -f /etc/nginx/sites-enabled/vps-proxy-hub-*
    rm -f /etc/nginx/sites-available/vps-proxy-hub-*

    if command -v yq &> /dev/null; then
        yq eval '.sites[] | .name' "$CONFIG_FILE" | while IFS= read -r site_name; do
            [[ -n "$site_name" ]] && process_site "$site_name"
        done
    else
        # Basic parsing for site names
        grep -A 50 "^sites:" "$CONFIG_FILE" | grep "name:" | sed 's/.*name: *["'\'']*//' | sed 's/["'\'']*.*//' | while IFS= read -r site_name; do
            [[ -n "$site_name" ]] && process_site "$site_name"
        done
    fi
}

# Process individual site configuration
process_site() {
    local site_name="$1"
    log "Processing site: $site_name"

    local server_names peer upstream_host upstream_port

    if command -v yq &> /dev/null; then
        server_names=$(yq eval ".sites[] | select(.name == \"$site_name\") | .server_names[]" "$CONFIG_FILE" | tr '\n' ' ')
        peer=$(yq eval ".sites[] | select(.name == \"$site_name\") | .peer" "$CONFIG_FILE")
    else
        server_names=$(extract_site_config "$site_name" "server_names")
        peer=$(extract_site_config "$site_name" "peer")
    fi

    if [[ -z "$peer" ]]; then
        log_error "No peer specified for site $site_name"; return 1
    fi

    # Get peer IP (WireGuard tunnel IP)
    local peer_ip
    peer_ip=$(get_peer_ip "$peer")
    if [[ -z "$peer_ip" ]]; then
        log_error "Could not determine IP for peer $peer"; return 1
    fi

    # Determine upstream configuration
    local upstream_config
    upstream_config=$(determine_upstream_config "$site_name" "$peer_ip") || return 1

    IFS="|" read -r upstream_host upstream_port <<< "$upstream_config"

    # Generate the virtual host
    generate_vhost "$site_name" "$server_names" "$upstream_host" "$upstream_port"

    log_success "Generated virtual host for $site_name"
}

# Helper function for basic YAML parsing (when yq not available)
extract_site_config() {
    local site_name="$1" key="$2"
    awk "
    /name:.*\"?${site_name}\"?/ { in_site = 1; next }
    in_site && /^[[:space:]]*-[[:space:]]*name:/ && !/name:.*\"?${site_name}\"?/ { in_site = 0 }
    in_site && /^[^[:space:]]/ && !/name:.*\"?${site_name}\"?/ { in_site = 0 }
    in_site && /${key}:/ {
        if (/${key}:.*\[/) {
            gsub(/.*\[/, \"\"); gsub(/\].*/, \"\"); gsub(/[\"',]/, \" \"); print \$0
        } else {
            gsub(/.*${key}:[[:space:]]*[\"']?/, \"\"); gsub(/[\"'].*/, \"\"); print \$0
        }
        next
    }" "$CONFIG_FILE"
}

# Get peer IP address from WireGuard address
get_peer_ip() {
    local peer_name="$1"
    if command -v yq &> /dev/null; then
        local address
        address=$(yq eval ".peers[] | select(.name == \"$peer_name\") | .address" "$CONFIG_FILE")
        echo "${address%/*}"  # Remove CIDR notation
    else
        awk "/name:.*\"?${peer_name}\"?/,/^[[:space:]]*-[[:space:]]*name:|^[^[:space:]]/ {
            if (/address:/) {
                gsub(/.*address:[[:space:]]*[\"']?/, \"\"); gsub(/\/[0-9]*/, \"\"); gsub(/[\"'].*/, \"\"); print \$0; exit
            }
        }" "$CONFIG_FILE"
    fi
}

# Determine upstream host and port configuration
determine_upstream_config() {
    local site_name="$1" peer_ip="$2"
    local is_docker container_name container_port port

    if command -v yq &> /dev/null; then
        is_docker=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.docker" "$CONFIG_FILE")
        container_name=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.container_name" "$CONFIG_FILE")
        container_port=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.container_port" "$CONFIG_FILE")
        port=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.port" "$CONFIG_FILE")
    else
        is_docker=$(extract_upstream_config "$site_name" "docker")
        container_name=$(extract_upstream_config "$site_name" "container_name")
        container_port=$(extract_upstream_config "$site_name" "container_port")
        port=$(extract_upstream_config "$site_name" "port")
    fi

    if [[ "$is_docker" == "true" ]]; then
        if [[ -n "$container_name" && -n "$container_port" ]]; then
            # For Docker containers, we still proxy to the peer IP but use the container port
            # The peer machine should handle container networking internally
            echo "${peer_ip}|${container_port}"
        else
            log_error "Docker upstream specified but container_name or container_port missing for $site_name"
            return 1
        fi
    else
        if [[ -n "$port" && "$port" != "null" ]]; then
            echo "${peer_ip}|${port}"
        else
            log_error "Port not specified for site $site_name"
            return 1
        fi
    fi
}

# Helper function to extract upstream config (when yq not available)
extract_upstream_config() {
    local site_name="$1" key="$2"
    awk "
    /name:.*\"?${site_name}\"?/ { in_site = 1; next }
    in_site && /upstream:/ { in_upstream = 1; next }
    in_upstream && /^[[:space:]]*[a-zA-Z_]+:/ && !/${key}:/ { if (!/^[[:space:]]+/) in_upstream = 0; next }
    in_upstream && /${key}:/ { gsub(/.*${key}:[[:space:]]*[\"']?/, \"\"); gsub(/[\"'].*/, \"\"); print \$0; exit }
    in_site && /^[[:space:]]*-[[:space:]]*name:/ && !/name:.*\"?${site_name}\"?/ { in_site = 0; in_upstream = 0 }
    " "$CONFIG_FILE"
}

# Generate virtual host configuration - FIXED VERSION
generate_vhost() {
    local site_name="$1" server_names="$2" upstream_host="$3" upstream_port="$4"

    local vhost_file="/etc/nginx/sites-available/vps-proxy-hub-${site_name}"

    # Clean up server names (remove quotes, brackets, commas)
    server_names=$(echo "$server_names" | sed 's/["\[\],]//g' | tr -s ' ')

    # Always generate configuration directly (ignore template with undefined placeholders)
    generate_vhost_direct "$vhost_file" "$server_names" "$upstream_host" "$upstream_port"

    # Enable the site (symlink to sites-enabled)
    ln -sf "$vhost_file" "/etc/nginx/sites-enabled/vps-proxy-hub-${site_name}"

    # Ensure only one site uses default_server (remove if present)
    rm -f /etc/nginx/sites-enabled/default

    log "Created and enabled virtual host: $vhost_file"
}

# Generate vhost file directly - FIXED VERSION
generate_vhost_direct() {
    local vhost_file="$1" server_names="$2" upstream_host="$3" upstream_port="$4"

    cat > "$vhost_file" << EOF
# HTTP: ACME + redirect to HTTPS
server {
  listen 80;
  listen [::]:80;
  server_name $server_names;

  # Let Certbot reach the challenge
  location ^~ /.well-known/acme-challenge/ {
    root /var/www/html;
    try_files \$uri =404;
  }

  # Redirect to HTTPS (will be uncommented after SSL setup)
  # return 301 https://\$host\$request_uri;
}

# HTTPS: proxy to WireGuard peer
server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name $server_names;

  # SSL configuration will be managed by Certbot
  # ssl_certificate     /path/to/cert;
  # ssl_certificate_key /path/to/key;

  # Debug header to confirm upstream
  add_header X-Proxy-Upstream "${upstream_host}:${upstream_port}" always;

  # Reverse proxy over WireGuard
  location / {
    proxy_pass http://${upstream_host}:${upstream_port};
    include /etc/nginx/conf.d/proxy.conf;
    proxy_next_upstream error timeout http_502 http_503 http_504;
  }

  # Optional health check
  location = /.proxy-hub-health {
    access_log off;
    add_header Content-Type text/plain;
    return 200 "OK\\n";
  }
}
EOF
}

# Test nginx configuration
test_nginx_config() {
    log "Testing Nginx configuration..."
    if nginx -t; then
        log_success "Nginx configuration test passed"
    else
        log_error "Nginx configuration test failed"
        log "Check the configuration files in /etc/nginx/sites-available/"
        exit 1
    fi
}

# Reload nginx
reload_nginx() {
    log "Reloading Nginx configuration..."
    if systemctl reload nginx; then
        log_success "Nginx reloaded successfully"
    else
        log_error "Failed to reload Nginx"
        log "Check nginx status: systemctl status nginx"
        exit 1
    fi
}

# Obtain SSL certificates and enable HTTPS redirects
obtain_ssl_certificates() {
    log "Obtaining SSL certificates with Let's Encrypt..."

    local email staging_flag=""
    email=$(get_config_value "tls.email")
    local use_staging
    use_staging=$(get_config_value "tls.use_staging" "false")

    if [[ "$use_staging" == "true" ]]; then
        staging_flag="--staging"
        log_warning "Using Let's Encrypt staging environment (test certificates)"
    fi

    if [[ -z "$email" ]]; then
        log_error "TLS email not configured in config.yaml"
        log "SSL certificates will need to be obtained manually"
        return 1
    fi

    # Process each site for SSL
    if command -v yq &> /dev/null; then
        yq eval '.sites[] | .name' "$CONFIG_FILE" | while IFS= read -r site_name; do
            [[ -n "$site_name" ]] && obtain_site_ssl "$site_name" "$email" "$staging_flag"
        done
    else
        grep -A 50 "^sites:" "$CONFIG_FILE" | grep "name:" | sed 's/.*name: *["'\'']*//' | sed 's/["'\'']*.*//' | while IFS= read -r site_name; do
            [[ -n "$site_name" ]] && obtain_site_ssl "$site_name" "$email" "$staging_flag"
        done
    fi
}

# Obtain SSL certificate for individual site
obtain_site_ssl() {
    local site_name="$1" email="$2" staging_flag="$3"

    log "Obtaining SSL certificate for site: $site_name"

    # Get server names for the site
    local server_names
    if command -v yq &> /dev/null; then
        server_names=$(yq eval ".sites[] | select(.name == \"$site_name\") | .server_names[]" "$CONFIG_FILE" | tr '\n' ' ')
    else
        server_names=$(extract_site_config "$site_name" "server_names")
    fi

    server_names=$(echo "$server_names" | sed 's/["\[\],]//g' | tr -s ' ')

    if [[ -z "$server_names" ]]; then
        log_error "No server names found for site $site_name"
        return 1
    fi

    # Build domain arguments for certbot
    local domain_args=""
    for domain in $server_names; do
        domain_args+=" -d $domain"
    done

    log "Requesting certificate for domains: $server_names"

    # Check for dry run mode
    local dry_run_flag=""
    local dry_run_on_apply
    dry_run_on_apply=$(get_config_value "ops.certbot_dry_run_on_apply" "false")
    if [[ "$dry_run_on_apply" == "true" ]]; then
        dry_run_flag="--dry-run"
        log "Performing certbot dry run (test mode)"
    fi

    # Run certbot to obtain certificate and configure nginx
    if [[ -n "$dry_run_flag" ]]; then
        # Dry run - just test certificate issuance
        if certbot certonly --nginx \
            --email "$email" \
            --agree-tos \
            --no-eff-email \
            $staging_flag \
            --dry-run \
            $domain_args; then
            log_success "SSL certificate dry run completed for $site_name"
        else
            log_error "Failed certbot dry run for $site_name"
            return 1
        fi
    else
        # Real certificate issuance and nginx configuration
        if certbot --nginx \
            --email "$email" \
            --agree-tos \
            --no-eff-email \
            --redirect \
            $staging_flag \
            $domain_args; then
            log_success "SSL certificate obtained and configured for $site_name"
            
            # Enable HTTPS redirect in the HTTP block
            enable_https_redirect "$site_name"
        else
            log_error "Failed to obtain SSL certificate for $site_name"
            log "Check that:"
            log "  - DNS records point to this VPS"
            log "  - Port 80 is accessible from the internet"
            log "  - No other web server is using port 80"
            return 1
        fi
    fi
}

# Enable HTTPS redirect in HTTP server block after SSL is configured
enable_https_redirect() {
    local site_name="$1"
    local vhost_file="/etc/nginx/sites-available/vps-proxy-hub-${site_name}"
    
    if [[ -f "$vhost_file" ]]; then
        # Uncomment the redirect line if it's commented
        sed -i 's/# return 301 https:/return 301 https:/' "$vhost_file"
        
        # If the redirect line doesn't exist, add it
        if ! grep -q "return 301 https:" "$vhost_file"; then
            # Add redirect after the ACME location block in HTTP server
            sed -i '/location.*acme-challenge/,/}/ { 
                /}/ a\\n  # Redirect to HTTPS\n  return 301 https://$host$request_uri;
            }' "$vhost_file"
        fi
        
        log "Enabled HTTPS redirect for $site_name"
    fi
}

# Run main function
main "$@"