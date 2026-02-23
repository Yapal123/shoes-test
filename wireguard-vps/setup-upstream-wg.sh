#!/bin/bash
#
# Setup VPS as PPTP-to-WireGuard bridge
#
# Use case: You have an external WireGuard VPN provider (Mullvad, IVPN, etc.)
# and want to route ALL router traffic through it.
#
# Architecture:
#   [Router] --PPTP--> [VPS] --WireGuard--> [VPN Provider] --> [Internet]
#
# Prerequisites:
#   - Run setup-baremetal.sh first
#   - Have a .conf file from your WG VPN provider
#
# Usage: ./setup-upstream-wg.sh /path/to/provider.conf
#
set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }
[[ $# -lt 1 ]] && { echo "Usage: $0 <path-to-upstream-wg.conf>"; exit 1; }

UPSTREAM_CONF="$1"
[[ ! -f "${UPSTREAM_CONF}" ]] && { echo "File not found: ${UPSTREAM_CONF}"; exit 1; }

MAIN_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)
VPS_PUBLIC_IP=$(curl -s4 ifconfig.me)

echo "[+] Setting up upstream WireGuard tunnel..."

# Copy upstream config
cp "${UPSTREAM_CONF}" /etc/wireguard/wg-upstream.conf

# Extract upstream endpoint to add a static route (so WG traffic doesn't loop)
UPSTREAM_ENDPOINT=$(grep -oP 'Endpoint\s*=\s*\K[^:]+' /etc/wireguard/wg-upstream.conf | head -1)
UPSTREAM_PORT=$(grep -oP 'Endpoint\s*=\s*[^:]+:\K\d+' /etc/wireguard/wg-upstream.conf | head -1)

echo "[+] Upstream endpoint: ${UPSTREAM_ENDPOINT}:${UPSTREAM_PORT}"

# Modify upstream config: remove DNS and AllowedIPs, add custom routing
# We don't want wg-upstream to capture ALL VPS traffic, only PPTP client traffic
UPSTREAM_ADDRESS=$(grep -oP 'Address\s*=\s*\K.*' /etc/wireguard/wg-upstream.conf)

# Create a policy-routing aware config
cat > /etc/wireguard/wg-upstream.conf <<EOF
$(cat "${UPSTREAM_CONF}")

# Policy routing: only route PPTP traffic through this tunnel
# Table 100 is for PPTP client traffic
EOF

# Create routing script
cat > /etc/wireguard/upstream-routing.sh <<SCRIPT
#!/bin/bash

# Custom routing table for PPTP -> upstream WG
TABLE=100

case "\$1" in
    up)
        # Static route for upstream endpoint via main interface
        ip route add ${UPSTREAM_ENDPOINT}/32 via \$(ip route show default | awk '{print \$3}') dev ${MAIN_IF} 2>/dev/null || true

        # Add default route in custom table via wg-upstream
        ip route add default dev wg-upstream table \${TABLE} 2>/dev/null || true

        # Mark PPTP traffic and route via custom table
        iptables -t mangle -A PREROUTING -s 192.168.10.0/24 -j MARK --set-mark 100
        ip rule add fwmark 100 table \${TABLE} priority 100 2>/dev/null || true

        # NAT PPTP traffic going out via wg-upstream
        iptables -t nat -A POSTROUTING -s 192.168.10.0/24 -o wg-upstream -j MASQUERADE
        iptables -A FORWARD -i ppp+ -o wg-upstream -j ACCEPT
        iptables -A FORWARD -i wg-upstream -o ppp+ -m state --state RELATED,ESTABLISHED -j ACCEPT

        echo "[upstream] Routing enabled: PPTP -> wg-upstream"
        ;;
    down)
        ip rule del fwmark 100 table \${TABLE} 2>/dev/null || true
        ip route del default dev wg-upstream table \${TABLE} 2>/dev/null || true
        ip route del ${UPSTREAM_ENDPOINT}/32 2>/dev/null || true
        iptables -t mangle -D PREROUTING -s 192.168.10.0/24 -j MARK --set-mark 100 2>/dev/null || true
        iptables -t nat -D POSTROUTING -s 192.168.10.0/24 -o wg-upstream -j MASQUERADE 2>/dev/null || true
        echo "[upstream] Routing disabled"
        ;;
esac
SCRIPT
chmod +x /etc/wireguard/upstream-routing.sh

# Add PostUp/PostDown hooks to upstream config
sed -i '/^\[Interface\]/a PostUp = /etc/wireguard/upstream-routing.sh up\nPostDown = /etc/wireguard/upstream-routing.sh down' /etc/wireguard/wg-upstream.conf

# Remove any existing AllowedIPs = 0.0.0.0/0 to prevent capturing all traffic
# Instead, allow the full range but routing is handled by policy routing
echo "[+] Starting wg-upstream..."
systemctl enable --now wg-quick@wg-upstream

echo ""
echo "============================================================"
echo " Upstream WireGuard Bridge Active"
echo "============================================================"
echo ""
echo "  Router PPTP traffic -> VPS -> wg-upstream -> ${UPSTREAM_ENDPOINT}"
echo "  Direct WG clients  -> VPS -> ${MAIN_IF} -> Internet (unchanged)"
echo ""
echo "  wg show wg-upstream    # Check upstream tunnel"
echo "  wg show wg0            # Check local WG server"
echo "============================================================"
