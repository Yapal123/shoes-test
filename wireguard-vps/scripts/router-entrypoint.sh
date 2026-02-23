#!/bin/bash
set -e

PPTP_SUBNET="${PPTP_SUBNET:-192.168.10.0/24}"
WG_SUBNET="${WG_SUBNET:-10.13.13.0/24}"

echo "=== VPN Router: bridging PPTP <-> WireGuard ==="
echo "PPTP subnet: ${PPTP_SUBNET}"
echo "WG subnet:   ${WG_SUBNET}"

sysctl -w net.ipv4.ip_forward=1

iptables -t nat -A POSTROUTING -s ${PPTP_SUBNET} -o wg0 -j MASQUERADE
iptables -A FORWARD -i ppp+ -o wg0 -j ACCEPT
iptables -A FORWARD -i wg0 -o ppp+ -m state --state RELATED,ESTABLISHED -j ACCEPT

iptables -t nat -A POSTROUTING -s ${WG_SUBNET} -o eth0 -j MASQUERADE
iptables -A FORWARD -i wg0 -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "iptables rules applied. Sleeping..."
exec tail -f /dev/null
