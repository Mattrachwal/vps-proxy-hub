#!/bin/bash
# Debug version of add-peer-key.sh with more robust parsing and verbose output

set -euo pipefail
umask 077   # enforce secure permissions on new files

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE_DEFAULT="$SCRIPT_DIR/../config.yaml"
CONFIG_FILE="$CONFIG_FILE_DEFAULT"
PEER_NAME=""
PUBLIC_KEY=""

# Load shared utilities (includes colors and logging functions)
source "$SCRIPT_DIR/../shared/utils.sh"
log()         { echo -e "${BLUE}[DEBUG]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# Parse arguments
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <peer-name> <public-key>"
    exit 1
fi

PEER_NAME="$1"
PUBLIC_KEY="$2"

log "Starting debug session for peer: $PEER_NAME"
log "Public key: $PUBLIC_KEY"
log "Config file: $CONFIG_FILE"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)."
    exit 1
fi

# Check config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file not found at: $CONFIG_FILE"
    exit 1
fi

log "Config file exists: $CONFIG_FILE"

# Check yq availability
have_yq=false
if command -v yq >/dev/null 2>&1; then 
    have_yq=true
    log "yq is available: $(yq --version)"
else
    log_warning "yq is not available, using fallback parsing"
fi

# Helper function to get config values
cfg_get() {
    local path="$1" default="${2:-}"
    if $have_yq; then
        local out
        out="$(yq -r "${path} // \"\"" "$CONFIG_FILE" 2>/dev/null || echo "")"
        [[ -n "$out" ]] && printf '%s\n' "$out" || printf '%s\n' "$default"
    else
        # fallback YAML parser (simple, expects dot-separated path)
        awk -v path="$path" -v def="$default" '
          BEGIN {
            n=split(path,p,".");
            for(i=2;i<=n;i++) want[i-1]=p[i];
          }
          {
            line=$0
            indent=match(line,/^([ ]*)/,m)? length(m[1]) : 0
            gsub(/^[ ]+/,"",line)
            if (line ~ /^#/ || line == "") next
            if (match(line,/^[^:]+:/)) {
              key=$0; sub(/:.*/,"",key); gsub(/^[ \t-]+/,"",key)
              level=indent/2
              ctx[level]=key
              for(j=level+1;j<=10;j++) delete ctx[j]
              val=line
              sub(/^[^:]+:[ ]*/,"",val)
              if (val != line) {
                ok=1
                for(k=1;k<length(want);k++) if(ctx[k]!=want[k]) ok=0
                if(ok && key==want[length(want)]) { gsub(/^["'\'']|["'\'']$/,"",val); print val; exit }
              }
            }
          }
          END { if(NR==0) print def }
        ' "$CONFIG_FILE" | { read v; [ -n "$v" ] && printf '%s\n' "$v" || printf '%s\n' "$default"; }
    fi
}

# Check peer configuration
log "Checking peer configuration in config.yaml..."
if $have_yq; then
    peer_exists="$(yq -r --arg n "$PEER_NAME" '.peers[]? | select(.name == $n) | .name // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    if [[ -n "$peer_exists" ]]; then
        log_success "Peer $PEER_NAME found in configuration"
        peer_addr="$(yq -r --arg n "$PEER_NAME" '.peers[]? | select(.name == $n) | .address // empty' "$CONFIG_FILE" 2>/dev/null || true)"
        peer_keepalive="$(yq -r --arg n "$PEER_NAME" '.peers[]? | select(.name == $n) | .keepalive // "25"' "$CONFIG_FILE" 2>/dev/null || echo "25")"
        log "Peer address: $peer_addr"
        log "Peer keepalive: $peer_keepalive"
    else
        log_error "Peer $PEER_NAME not found in configuration"
        exit 1
    fi
else
    log_warning "Cannot verify peer configuration without yq"
fi

# Get paths
PEERS_DIR="$(cfg_get '.vps.wireguard.peers_dir' '/etc/wireguard/peers')"
VPS_PRIVATE_KEY_PATH="$(cfg_get '.vps.wireguard.private_key_path' '/etc/wireguard/vps-private.key')"
VPS_ADDRESS="$(cfg_get '.vps.wireguard.vps_address' '10.8.0.1/24')"
LISTEN_PORT="$(cfg_get '.vps.wireguard.listen_port' '51820')"

log "Peers directory: $PEERS_DIR"
log "VPS private key path: $VPS_PRIVATE_KEY_PATH"
log "VPS address: $VPS_ADDRESS"
log "Listen port: $LISTEN_PORT"

# Create peers directory
mkdir -p "$PEERS_DIR"
chmod 700 "$PEERS_DIR"
log "Created/verified peers directory: $PEERS_DIR"

# Save public key
echo "$PUBLIC_KEY" > "$PEERS_DIR/${PEER_NAME}.pub"
chmod 600 "$PEERS_DIR/${PEER_NAME}.pub"
log_success "Saved public key: $PEERS_DIR/${PEER_NAME}.pub"

# Check VPS private key
if [[ ! -f "$VPS_PRIVATE_KEY_PATH" ]]; then
    log_error "VPS private key not found: $VPS_PRIVATE_KEY_PATH"
    echo "Generate with:"
    echo "  sudo sh -c 'wg genkey | tee $VPS_PRIVATE_KEY_PATH | wg pubkey > /etc/wireguard/vps-public.key'"
    exit 1
fi

VPS_PRIVATE_KEY="$(cat "$VPS_PRIVATE_KEY_PATH")"
log "VPS private key loaded (length: ${#VPS_PRIVATE_KEY} chars)"

# Build wg0.conf
WG_CONF="/etc/wireguard/wg0.conf"
log "Building WireGuard configuration: $WG_CONF"

if [[ -f "$WG_CONF" ]]; then
    cp "$WG_CONF" "/etc/wireguard/wg0.conf.backup.$(date +%Y%m%d_%H%M%S)"
    log "Backed up existing wg0.conf"
fi

cat > "$WG_CONF" <<EOF
# VPS WireGuard Configuration
# Generated by debug script

[Interface]
PrivateKey = $VPS_PRIVATE_KEY
Address    = $VPS_ADDRESS
ListenPort = $LISTEN_PORT
SaveConfig = false

# Enable packet forwarding and NAT
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o \$(ip route show default | awk '/default/ { print \$5 ; exit }') -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o \$(ip route show default | awk '/default/ { print \$5 ; exit }') -j MASQUERADE

EOF

log "Base configuration written"

# Add all peers
PEERS_ADDED=0
shopt -s nullglob
for keyfile in "$PEERS_DIR"/*.pub; do
    [[ -f "$keyfile" ]] || continue
    PK="$(cat "$keyfile")"
    NAME="$(basename "$keyfile" .pub)"

    log "Processing peer: $NAME"

    ADDR="$( $have_yq && yq -r --arg n "$NAME" '.peers[]? | select(.name == $n) | .address // empty' "$CONFIG_FILE" 2>/dev/null || echo "" )"
    KA="$( $have_yq && yq -r --arg n "$NAME" '.peers[]? | select(.name == $n) | .keepalive // "25"' "$CONFIG_FILE" 2>/dev/null || echo "25" )"

    if [[ -z "$ADDR" ]]; then
        log_warning "Skipping peer $NAME: address not found in config.yaml"
        continue
    fi

    cat >> "$WG_CONF" <<EOF

# Peer: $NAME
[Peer]
PublicKey           = $PK
AllowedIPs          = $ADDR
PersistentKeepalive = $KA
EOF
    ((PEERS_ADDED++))
    log_success "Added peer: $NAME ($ADDR)"
done
shopt -u nullglob

chmod 600 "$WG_CONF"
log "Set permissions on $WG_CONF"

if (( PEERS_ADDED == 0 )); then
    log_warning "No peers added to configuration!"
else
    log_success "Added $PEERS_ADDED peer(s) to configuration"
fi

# Test configuration
log "Testing WireGuard configuration..."
if wg-quick strip wg0 >/dev/null 2>&1; then
    log_success "Configuration syntax is valid"
else
    log_error "Configuration syntax error!"
    exit 1
fi

# Restart WireGuard service
echo
log_success "Configuration updated successfully. Restarting WireGuard service..."

if systemctl is-active --quiet wg-quick@wg0; then
    log "Stopping WireGuard service..."
    systemctl stop wg-quick@wg0 && log_success "WireGuard service stopped"
    sleep 1
fi

log "Starting WireGuard service..."
if systemctl start wg-quick@wg0; then
    log_success "WireGuard service started"
else
    log_error "Failed to start WireGuard service"
    exit 1
fi
sleep 3

if systemctl is-active --quiet wg-quick@wg0; then
    log_success "WireGuard service is active and running"
    sleep 2
    echo
    log_success "Current WireGuard status:"
    wg show wg0 2>/dev/null || log_warning "wg show failed - interface may not be ready yet"
    log_success "WireGuard interface is working correctly - peer added and service restarted!"
else
    log_error "WireGuard failed to start. Check: journalctl -u wg-quick@wg0"
    exit 1
fi

log_success "Peer $PEER_NAME added successfully!"
