#!/bin/bash
#
# Add a new WireGuard peer to an existing setup
# Usage: ./add-wg-peer.sh <peer_name>
#
set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }
[[ $# -lt 1 ]] && { echo "Usage: $0 <peer_name>"; exit 1; }

PEER_NAME="$1"
WG_DIR="/etc/wireguard"
VPS_PUBLIC_IP=$(curl -s4 ifconfig.me)
WG_PORT=$(grep -oP 'ListenPort\s*=\s*\K\d+' "${WG_DIR}/wg0.conf")
SERVER_PUB=$(cat "${WG_DIR}/server_public.key")
WG_DNS="1.1.1.1, 8.8.8.8"

# Find next available IP
LAST_IP=$(grep -oP '10\.13\.13\.\K\d+' "${WG_DIR}/wg0.conf" | sort -n | tail -1)
NEXT_IP=$((LAST_IP + 1))

if [[ ${NEXT_IP} -gt 254 ]]; then
    echo "No more IPs available in subnet"
    exit 1
fi

PEER_DIR="${WG_DIR}/peers/${PEER_NAME}"
mkdir -p "${PEER_DIR}"

wg genkey | tee "${PEER_DIR}/private.key" | wg pubkey > "${PEER_DIR}/public.key"
wg genpsk > "${PEER_DIR}/preshared.key"

PEER_PRIV=$(cat "${PEER_DIR}/private.key")
PEER_PUB=$(cat "${PEER_DIR}/public.key")
PEER_PSK=$(cat "${PEER_DIR}/preshared.key")
PEER_IP="10.13.13.${NEXT_IP}/32"

# Add to server config
cat >> "${WG_DIR}/wg0.conf" <<EOF

[Peer]
# ${PEER_NAME}
PublicKey = ${PEER_PUB}
PresharedKey = ${PEER_PSK}
AllowedIPs = ${PEER_IP}
EOF

# Create client config
cat > "${PEER_DIR}/${PEER_NAME}.conf" <<EOF
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

qrencode -t ansiutf8 < "${PEER_DIR}/${PEER_NAME}.conf" > "${PEER_DIR}/${PEER_NAME}_qr.txt" 2>/dev/null || true
qrencode -t png -o "${PEER_DIR}/${PEER_NAME}_qr.png" < "${PEER_DIR}/${PEER_NAME}.conf" 2>/dev/null || true

# Hot-reload WG (no downtime)
wg set wg0 peer "${PEER_PUB}" preshared-key "${PEER_DIR}/preshared.key" allowed-ips "${PEER_IP}"

echo ""
echo "Peer '${PEER_NAME}' added:"
echo "  IP:     ${PEER_IP}"
echo "  Config: ${PEER_DIR}/${PEER_NAME}.conf"
echo ""
echo "QR code:"
cat "${PEER_DIR}/${PEER_NAME}_qr.txt" 2>/dev/null || echo "(qrencode not installed)"
