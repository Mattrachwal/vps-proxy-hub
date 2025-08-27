#!/bin/bash
# VPS Setup - Nginx Virtual Hosts Configuration
# Generates Nginx virtual hosts from config.yaml (HTTP-only first) and then obtains SSL certificates

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

    # Process each site in the configuration (HTTP-only first)
    process_sites

    # Test nginx configuration (should pass without certs)
    test_nginx_config

    # Reload nginx to apply HTTP sites
    reload_nginx

    # Obtain SSL certificates and enable HTTPS+redirect
    obtain_ssl_certificates

    log_success "Nginx virtual hosts configuration completed"
}

# --- Helpers ---------------------------------------------------------------

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

get_peer_ip() {
    local peer_name="$1"
    if command -v yq &> /dev/null; then
        local address
        address=$(yq eval ".peers[] | select(.name == \"$peer_name\") | .address" "$CONFIG_FILE")
        echo "${address%/*}"
    else
        awk "/name:.*\"?${peer_name}\"?/,/^[[:space:]]*-[[:space:]]*name:|^[^[:space:]]/ {
            if (/address:/) {
                gsub(/.*address:[[:space:]]*[\"']?/, \"\"); gsub(/\/[0-9]*/, \"\"); gsub(/[\"'].*/, \"\"); print \$0; exit
            }
        }" "$CONFIG_FILE"
    fi
}

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

determine_upstream_url() {
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
            echo "http://${container_name}:${container_port}"
        else
            log_error "Docker upstream specified but container_name or container_port missing for $site_name"; return 1
        fi
    else
        if [[ -n "$port" ]]; then
            echo "http://${peer_ip}:${port}"
        else
            log_error "Port not specified for site $site_name"; return 1
        fi
    fi
}

# Strip TLS, HSTS, HTTPS redirects, and duplicate proxy/security headers from a vhost file.
sanitize_vhost_http_only() {
  local file="$1"; [[ -f "$file" ]] || return 0

  # Ensure HTTP-only (no TLS listeners or HSTS/redirects yet)
  sed -i -E '/^\s*listen\s+.*443.*(ssl|http2)/d' "$file"
  sed -i -E '/^\s*add_header\s+Strict-Transport-Security\b/d' "$file"
  sed -i -E '/^\s*return\s+301\s+https:\/\//d' "$file"

  # Drop per-site proxy knobs already defined globally in /etc/nginx/conf.d/proxy.conf
  sed -i -E '
    /^\s*proxy_(connect|send|read)_timeout\b/d;
    /^\s*proxy_buffering\b/d;
    /^\s*proxy_buffer_size\b/d;
    /^\s*proxy_buffers\b/d;
    /^\s*proxy_busy_buffers_size\b/d;
    /^\s*proxy_http_version\b/d;
    /^\s*proxy_set_header\s+(Host|X-Real-IP|X-Forwarded-For|X-Forwarded-Proto|X-Forwarded-Host|X-Forwarded-Port|Upgrade|Connection)\b/d;
    /^\s*proxy_hide_header\s+(X-Frame-Options|X-Content-Type-Options|X-XSS-Protection)\b/d;
  ' "$file"

  # Drop global security headers (they live in nginx.conf)
  sed -i -E '
    /^\s*add_header\s+X-Frame-Options\b/d;
    /^\s*add_header\s+X-Content-Type-Options\b/d;
    /^\s*add_header\s+X-XSS-Protection\b/d;
    /^\s*add_header\s+Referrer-Policy\b/d;
  ' "$file"

  # Drop gzip in server{}
  sed -i -E '/^\s*gzip\b/d; /^\s*gzip_.*/d;' "$file"

  # Drop global ssl_* (keep only cert lines if certbot later adds them)
  sed -i -E '/^\s*ssl_(protocols|ciphers|prefer_server_ciphers|session_(cache|timeout|tickets)|stapling|stapling_verify)\b/d;' "$file"
}

# --- Site processing -------------------------------------------------------

process_sites() {
    log "Processing sites from configuration..."

    # Tightened cleanup scope: remove only this app's vhosts
    log "Removing existing virtual host configurations..."
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

process_site() {
    local site_name="$1"
    log "Processing site: $site_name"

    local server_names peer upstream_url

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

    local peer_ip
    peer_ip=$(get_peer_ip "$peer")
    if [[ -z "$peer_ip" ]]; then
        log_error "Could not determine IP for peer $peer"; return 1
    fi

    upstream_url=$(determine_upstream_url "$site_name" "$peer_ip") || return 1

    generate_vhost_http_only "$site_name" "$server_names" "$upstream_url"

    log_success "Generated virtual host for $site_name"
}

generate_vhost_http_only() {
    local site_name="$1" server_names="$2" upstream_url="$3"

    local vhost_file="/etc/nginx/sites-available/vps-proxy-hub-${site_name}"
    local template_file="$SCRIPT_DIR/../templates/nginx-vhost.template"

    # Clean server names
    server_names=$(echo "$server_names" | sed 's/["\[\],]//g' | tr -s ' ')

    if [[ -f "$template_file" ]]; then
        # If you keep a template, it MUST be HTTP-only; sanitize just in case.
        substitute_template "$template_file" "$vhost_file" \
            "SITE_NAME=$site_name" \
            "SERVER_NAMES=$server_names" \
            "UPSTREAM_URL=$upstream_url"
    else
        generate_vhost_http_only_direct "$vhost_file" "$site_name" "$server_names" "$upstream_url"
    fi

    # Sanitize: enforce HTTP-only and remove duplicate directives
    sanitize_vhost_http_only "$vhost_file"

    # Enable the site (symlink)
    ln -sf "$vhost_file" "/etc/nginx/sites-enabled/vps-proxy-hub-${site_name}"

    log "Created virtual host: $vhost_file"
}

generate_vhost_http_only_direct() {
    local vhost_file="$1" site_name="$2" server_names="$3" upstream_url="$4"

    cat > "$vhost_file" << EOF
# VPS Proxy Hub - Virtual Host for $site_name
# Generated automatically - HTTP-only (TLS will be added by certbot --nginx)

server {
    listen 80;
    listen [::]:80;
    server_name $server_names;

    # ACME challenge for Let's Encrypt
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
        default_type "text/plain";
        access_log off;
    }

    # Application proxy over HTTP (TLS added later by certbot)
    location / {
        # Shared proxy settings
        include /etc/nginx/conf.d/proxy.conf;

        # Upstream via WireGuard peer
        proxy_pass $upstream_url;

        # Handle connection errors gracefully
        proxy_next_upstream error timeout http_502 http_503 http_504;
    }

    # Health check
    location = /.proxy-hub-health {
        access_log off;
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }
}
EOF
}

# --- Actions ---------------------------------------------------------------

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

ob
