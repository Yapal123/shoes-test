#!/bin/bash
#
# WireGuard + PPTP Bridge Setup for VPS (bare metal, no Docker)
#
# Architecture:
#   [Router] --PPTP--> [VPS: pptpd + wg0] --WireGuard--> [Internet]
#                            |
#   [Phone/Laptop] ---WG----+
#
# Run as root on a fresh Ubuntu/Debian VPS.
#
set -euo pipefail

# ============================================================
# CONFIGURATION — edit these before running
# ============================================================

VPS_PUBLIC_IP="${VPS_PUBLIC_IP:-$(curl -s4 ifconfig.me)}"
WG_PORT="${WG_PORT:-51820}"
WG_SUBNET="10.13.13.0/24"
WG_SERVER_IP="10.13.13.1/24"
WG_DNS="1.1.1.1, 8.8.8.8"

# Number of WG peers to generate (for direct WG clients: phone, laptop, etc.)
WG_PEER_COUNT="${WG_PEER_COUNT:-3}"

PPTP_LOCAL_IP="192.168.10.1"
PPTP_REMOTE_RANGE="192.168.10.100-200"
PPTP_USERNAME="${PPTP_USERNAME:-router}"
PPTP_PASSWORD="${PPTP_PASSWORD:-$(openssl rand -base64 16)}"

# Main network interface (auto-detect)
MAIN_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)

# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[!]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && err "Run as root"

log "VPS IP: ${VPS_PUBLIC_IP}"
log "Main interface: ${MAIN_IF}"

# ============================================================
# 1. Install packages
# ============================================================
log "Installing packages..."
apt-get update -qq
apt-get install -y -qq wireguard wireguard-tools pptpd iptables-persistent qrencode

# ============================================================
# 2. Enable IP forwarding
# ============================================================
log "Enabling IP forwarding..."
cat > /etc/sysctl.d/99-vpn.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
EOF
sysctl --system > /dev/null

# ============================================================
# 3. WireGuard server setup
# ============================================================
log "Setting up WireGuard..."

WG_DIR="/etc/wireguard"
mkdir -p "${WG_DIR}/peers"
chmod 700 "${WG_DIR}"

umask 077
wg genkey | tee "${WG_DIR}/server_private.key" | wg pubkey > "${WG_DIR}/server_public.key"

SERVER_PRIV=$(cat "${WG_DIR}/server_private.key")
SERVER_PUB=$(cat "${WG_DIR}/server_public.key")

cat > "${WG_DIR}/wg0.conf" <<EOF
[Interface]
Address = ${WG_SERVER_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}

# NAT for WG clients -> internet
PostUp = iptables -t nat -A POSTROUTING -s ${WG_SUBNET} -o ${MAIN_IF} -j MASQUERADE
PostUp = iptables -A FORWARD -i wg0 -o ${MAIN_IF} -j ACCEPT
PostUp = iptables -A FORWARD -i ${MAIN_IF} -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# NAT for PPTP clients -> internet (through VPS, not through wg0)
PostUp = iptables -t nat -A POSTROUTING -s 192.168.10.0/24 -o ${MAIN_IF} -j MASQUERADE
PostUp = iptables -A FORWARD -i ppp+ -o ${MAIN_IF} -j ACCEPT
PostUp = iptables -A FORWARD -i ${MAIN_IF} -o ppp+ -m state --state RELATED,ESTABLISHED -j ACCEPT

PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET} -o ${MAIN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -o ${MAIN_IF} -j ACCEPT
PostDown = iptables -D FORWARD -i ${MAIN_IF} -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s 192.168.10.0/24 -o ${MAIN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i ppp+ -o ${MAIN_IF} -j ACCEPT
PostDown = iptables -D FORWARD -i ${MAIN_IF} -o ppp+ -m state --state RELATED,ESTABLISHED -j ACCEPT

EOF

# Generate peers
for i in $(seq 1 "${WG_PEER_COUNT}"); do
    PEER_DIR="${WG_DIR}/peers/peer${i}"
    mkdir -p "${PEER_DIR}"

    wg genkey | tee "${PEER_DIR}/private.key" | wg pubkey > "${PEER_DIR}/public.key"
    wg genpsk > "${PEER_DIR}/preshared.key"

    PEER_PRIV=$(cat "${PEER_DIR}/private.key")
    PEER_PUB=$(cat "${PEER_DIR}/public.key")
    PEER_PSK=$(cat "${PEER_DIR}/preshared.key")
    PEER_IP="10.13.13.$((i + 1))/32"

    # Add peer to server config
    cat >> "${WG_DIR}/wg0.conf" <<EOF
[Peer]
# peer${i}
PublicKey = ${PEER_PUB}
PresharedKey = ${PEER_PSK}
AllowedIPs = ${PEER_IP}

EOF

    # Create client config
    cat > "${PEER_DIR}/peer${i}.conf" <<EOF
[Interface]
PrivateKey = ${PEER_PRIV}
Address = ${PEER_IP}
DNS = ${WG_DNS}

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${PEER_PSK}
Endpoint = ${VPS_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    # Generate QR code
    qrencode -t ansiutf8 < "${PEER_DIR}/peer${i}.conf" > "${PEER_DIR}/peer${i}_qr.txt" 2>/dev/null || true
    qrencode -t png -o "${PEER_DIR}/peer${i}_qr.png" < "${PEER_DIR}/peer${i}.conf" 2>/dev/null || true

    log "  Peer ${i}: IP=${PEER_IP} config=${PEER_DIR}/peer${i}.conf"
done

chmod 600 "${WG_DIR}/wg0.conf"

# ============================================================
# 4. PPTP server setup (for router)
# ============================================================
log "Setting up PPTP server..."

cat > /etc/pptpd.conf <<EOF
option /etc/ppp/pptpd-options
logwtmp
localip ${PPTP_LOCAL_IP}
remoteip ${PPTP_REMOTE_RANGE}
EOF

cat > /etc/ppp/pptpd-options <<EOF
name pptpd
refuse-pap
refuse-chap
refuse-mschap
require-mschap-v2
require-mppe-128
ms-dns 1.1.1.1
ms-dns 8.8.8.8
proxyarp
lock
nobsdcomp
novj
novjccomp
nologfd
EOF

cat > /etc/ppp/chap-secrets <<EOF
# client    server  secret          IP addresses
${PPTP_USERNAME}    pptpd   ${PPTP_PASSWORD}    *
EOF
chmod 600 /etc/ppp/chap-secrets

# ============================================================
# 5. Firewall rules
# ============================================================
log "Configuring firewall..."

# Allow WireGuard port
iptables -A INPUT -p udp --dport "${WG_PORT}" -j ACCEPT
# Allow PPTP
iptables -A INPUT -p tcp --dport 1723 -j ACCEPT
iptables -A INPUT -p gre -j ACCEPT

# Save rules
netfilter-persistent save 2>/dev/null || true

# ============================================================
# 6. Enable and start services
# ============================================================
log "Starting services..."

systemctl enable --now wg-quick@wg0
systemctl enable --now pptpd

# ============================================================
# 7. Print summary
# ============================================================
echo ""
echo "============================================================"
echo -e "${GREEN} VPN Setup Complete${NC}"
echo "============================================================"
echo ""
echo "WireGuard:"
echo "  Server IP:    ${VPS_PUBLIC_IP}:${WG_PORT}"
echo "  Interface:    wg0 (${WG_SERVER_IP})"
echo "  Peers:        ${WG_PEER_COUNT} configs in ${WG_DIR}/peers/"
echo ""
echo "  To show QR for peer1:"
echo "    cat ${WG_DIR}/peers/peer1/peer1_qr.txt"
echo ""
echo "PPTP (for router):"
echo "  Server:       ${VPS_PUBLIC_IP}:1723"
echo "  Username:     ${PPTP_USERNAME}"
echo "  Password:     ${PPTP_PASSWORD}"
echo "  Router will get IP from: ${PPTP_REMOTE_RANGE}"
echo ""
echo "Management:"
echo "  wg show                          # WG status"
echo "  systemctl status wg-quick@wg0    # WG service"
echo "  systemctl status pptpd           # PPTP service"
echo "  bash $(dirname "$0")/add-wg-peer.sh peer_name  # Add new WG peer"
echo "============================================================"

# Save credentials
cat > /root/vpn-credentials.txt <<EOF
=== VPN Credentials (generated $(date)) ===

WireGuard Server: ${VPS_PUBLIC_IP}:${WG_PORT}
WireGuard Peers: ${WG_DIR}/peers/

PPTP Server: ${VPS_PUBLIC_IP}
PPTP Username: ${PPTP_USERNAME}
PPTP Password: ${PPTP_PASSWORD}
EOF
chmod 600 /root/vpn-credentials.txt
log "Credentials saved to /root/vpn-credentials.txt"
