#!/bin/bash
# VPS Setup - Nginx Installation and Basic Configuration
# Installs Nginx and configures it for reverse proxy with security headers
# - All ssl_* live in /etc/nginx/conf.d/ssl.conf
# - All proxy_* + websocket headers live in /etc/nginx/conf.d/proxy.conf
# - Global security headers/gzip live in nginx.conf
# - Per-site vhosts should only set server_name, cert paths, locations, and proxy_pass

set -euo pipefail

# Load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

main() {
    log "Starting Nginx installation and configuration..."

    check_root
    check_config

    install_nginx
    configure_nginx_security      # nginx.conf (no ssl_* here)
    setup_ssl_config              # central SSL knobs (http{} scope)
    setup_proxy_snippet           # central proxy knobs (include inside location)
    install_certbot
    configure_nginx_logrotate

    # De-duplicate any existing vhosts and ensure proper symlinks
    dedupe_all_vhosts "/etc/nginx/sites-available"

    enable_nginx_service

    log_success "Nginx installation and basic configuration completed"
}

install_nginx() {
    log "Installing Nginx..."

    if command -v nginx &>/dev/null; then
        log "Nginx is already installed"
        return 0
    fi

    if command -v apt-get &>/dev/null; then
        apt-get update
        apt-get install -y nginx
    elif command -v yum &>/dev/null; then
        yum install -y epel-release
        yum install -y nginx
    elif command -v dnf &>/dev/null; then
        dnf install -y nginx
    else
        log_error "Unsupported distribution for Nginx installation"
        exit 1
    fi

    if command -v nginx &>/dev/null; then
        log_success "Nginx installed successfully"
        nginx -v
    else
        log_error "Nginx installation failed"
        exit 1
    fi
}

configure_nginx_security() {
    log "Configuring Nginx security settings..."

    backup_file "/etc/nginx/nginx.conf"

    cat > /etc/nginx/nginx.conf << 'EOF'
# VPS Proxy Hub - Nginx Configuration
# Optimized for reverse proxy with security and performance

user www-data;
worker_processes auto;
pid /run/nginx.pid;

# Load dynamic modules
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    ##
    # Basic Settings
    ##
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 15;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 100M;

    # Buffer settings
    client_body_buffer_size 128k;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 4k;
    output_buffers 1 32k;
    postpone_output 1460;

    # Timeout settings
    client_header_timeout 3m;
    client_body_timeout 3m;
    send_timeout 3m;

    ##
    # MIME Types
    ##
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ##
    # Security Headers (applied to all sites)
    ##
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    ##
    # Logging Settings
    ##
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                   '$status $body_bytes_sent "$http_referer" '
                   '"$http_user_agent" "$http_x_forwarded_for" '
                   'rt=$request_time uct="$upstream_connect_time" '
                   'uht="$upstream_header_time" urt="$upstream_response_time"';

    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log;

    ##
    # Gzip Settings
    ##
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml
        application/xml+rss
        application/atom+xml
        image/svg+xml;

    ##
    # Rate Limiting
    ##
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=general:10m rate=30r/s;

    ##
    # Map for handling websockets
    ##
    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    ##
    # Default server block (catch-all)
    ##
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;
        return 444;
    }

    ##
    # Include additional configuration files
    ##
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

    # Fix user directive for CentOS/RHEL/Fedora
    if command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        sed -i 's/user www-data;/user nginx;/' /etc/nginx/nginx.conf
    fi

    ensure_directory "/etc/nginx/conf.d" "755"
    ensure_directory "/etc/nginx/sites-available" "755"
    ensure_directory "/etc/nginx/sites-enabled" "755"

    # Remove Debian's default site completely so it can't clash with the catch-all
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-available/default
    rm -f /var/www/html/index.*

    log_success "Nginx security configuration completed"
}

setup_ssl_config() {
    log "Setting up SSL/TLS configuration (global)..."

    cat > /etc/nginx/conf.d/ssl.conf << 'EOF'
# VPS Proxy Hub - SSL/TLS Configuration (global http{} scope)

# SSL session settings
ssl_session_cache shared:le_nginx_SSL:10m;
ssl_session_timeout 1440m;
ssl_session_tickets off;

# SSL protocols and ciphers
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";

# OCSP stapling
ssl_stapling on;
ssl_stapling_verify on;

# Resolvers (tuned)
resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 valid=60s;
resolver_timeout 2s;
EOF

    log_success "Global SSL/TLS configuration created"
}

setup_proxy_snippet() {
    log "Creating shared proxy snippet (global)..."

    cat > /etc/nginx/conf.d/proxy.conf << 'EOF'
# VPS Proxy Hub - Proxy Configuration (include inside location{} with proxy_pass)

# Proxy headers
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Port $server_port;

# Proxy timeouts
proxy_connect_timeout 60s;
proxy_send_timeout 60s;
proxy_read_timeout 60s;

# Proxy buffering
proxy_buffering on;
proxy_buffer_size 4k;
proxy_buffers 8 4k;
proxy_busy_buffers_size 8k;

# WebSocket support
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;

# Don't proxy server headers we set globally
proxy_hide_header X-Frame-Options;
proxy_hide_header X-Content-Type-Options;
proxy_hide_header X-XSS-Protection;
EOF

    log_success "Shared proxy snippet created"
}

install_certbot() {
    log "Installing Certbot for Let's Encrypt..."

    if ! command -v certbot &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get install -y certbot python3-certbot-nginx
        elif command -v yum &>/dev/null; then
            yum install -y epel-release
            yum install -y certbot python2-certbot-nginx
        elif command -v dnf &>/dev/null; then
            dnf install -y certbot python3-certbot-nginx
        else
            log_warning "Could not install certbot automatically"
        fi
    fi

    # Prefer systemd timer when present; otherwise, add cron
    if systemctl list-unit-files | grep -q '^certbot.timer'; then
        systemctl enable --now certbot.timer || true
        log "Using systemd certbot.timer for renewals"
    elif [[ -f /etc/crontab ]] && command -v certbot &>/dev/null; then
        if ! grep -q "certbot renew" /etc/crontab; then
            echo "0 12 * * * root certbot renew --quiet" >> /etc/crontab
            log "Added certbot renewal to crontab"
        fi
    fi

    if command -v certbot &>/dev/null; then
        log_success "Certbot installed successfully"
        certbot --version
    else
        log_error "Certbot installation failed"
        exit 1
    fi
}

configure_nginx_logrotate() {
    log "Configuring Nginx log rotation..."

    [[ -f /etc/logrotate.d/nginx ]] && backup_file "/etc/logrotate.d/nginx"

    cat > /etc/logrotate.d/nginx << 'EOF'
/var/log/nginx/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    sharedscripts
    prerotate
        if [ -d /etc/logrotate.d/httpd-prerotate ]; then \
            run-parts /etc/logrotate.d/httpd-prerotate; \
        fi
    endscript
    postrotate
        invoke-rc.d nginx rotate >/dev/null 2>&1 || true
    endscript
}
EOF

    if command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        sed -i 's/www-data adm/nginx nginx/' /etc/logrotate.d/nginx
        sed -i 's/invoke-rc.d nginx rotate/systemctl reload nginx/' /etc/logrotate.d/nginx
    fi

    log_success "Nginx log rotation configured"
}

# --- De-duplication helpers for existing vhosts ---

dedupe_vhost() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    # Remove proxy_* that belong to global proxy.conf
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

    # Remove security headers duplicated in server{}
    sed -i -E '
/^\s*add_header\s+X-Frame-Options\b/d;
/^\s*add_header\s+X-Content-Type-Options\b/d;
/^\s*add_header\s+X-XSS-Protection\b/d;
/^\s*add_header\s+Referrer-Policy\b/d;
' "$file"

    # Remove gzip in server{}
    sed -i -E '
/^\s*gzip\b/d;
/^\s*gzip_.*/d;
' "$file"

    # Remove ssl_* in server{} (global in ssl.conf; keep only cert paths)
    sed -i -E '
/^\s*ssl_(protocols|ciphers|prefer_server_ciphers|session_(cache|timeout|tickets)|stapling|stapling_verify)\b/d;
' "$file"

    # Ensure shared proxy snippet is included before first proxy_pass in each location block
    awk '
    BEGIN {in_loc=0; inserted=0}
    /^\s*location[^{]*\{/ {in_loc=1; inserted=0}
    in_loc && /proxy_pass/ && !inserted {
        print "        include /etc/nginx/conf.d/proxy.conf;";
        inserted=1
    }
    /\}/ {in_loc=0}
    {print}
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

dedupe_all_vhosts() {
    local dir="${1:-/etc/nginx/sites-available}"
    local enabled="/etc/nginx/sites-enabled"
    [[ -d "$dir" ]] || return 0
    ensure_directory "$enabled" "755"

    shopt -s nullglob
    for f in "$dir"/*; do
        [[ -f "$f" ]] || continue

        # Skip Debian's default site to avoid re-linking it
        [[ "$(basename "$f")" == "default" ]] && continue

        log "De-duplicating vhost: $f"
        dedupe_vhost "$f"

        # Keep sites-enabled as a symlink to sites-available (Debian-style)
        local name src dst real_src real_dst
        name="$(basename "$f")"
        src="$f"
        dst="$enabled/$name"

        real_src="$(readlink -f "$src")"
        real_dst="$(readlink -f "$dst" 2>/dev/null || true)"

        if [[ ! -e "$dst" ]]; then
            ln -s "$src" "$dst"
            continue
        fi

        # If already pointing to same file, do nothing
        if [[ "$real_dst" == "$real_src" ]]; then
            continue
        fi

        # Replace whatever is there with a symlink
        rm -f "$dst"
        ln -s "$src" "$dst"
    done
}

enable_nginx_service() {
    log "Enabling and starting Nginx service..."

    if ! nginx -t; then
        log_error "Nginx configuration test failed"
        exit 1
    fi

    systemctl enable nginx

    if systemctl is-active --quiet nginx; then
        systemctl reload nginx || systemctl restart nginx
    else
        systemctl start nginx
    fi

    wait_for_service "nginx"

    nginx -t || { log_error "Nginx configuration test failed after start"; exit 1; }

    # Quick response smoke test (catch-all returns 444)
    if curl -s -o /dev/null -w "%{http_code}" http://localhost | grep -q "444"; then
        log_success "Nginx is responding (444 for unknown hosts as expected)"
    else
        log_warning "Nginx response test inconclusive"
    fi

    log_success "Nginx service is running and enabled"
}

# Run main function
main "$@"
