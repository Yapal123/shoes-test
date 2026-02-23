#!/bin/bash
set -e

PPTP_LOCAL_IP="${PPTP_LOCAL_IP:-192.168.10.1}"
PPTP_REMOTE_IP_RANGE="${PPTP_REMOTE_IP_RANGE:-192.168.10.100-200}"
PPTP_USERNAME="${PPTP_USERNAME:-router}"
PPTP_PASSWORD="${PPTP_PASSWORD:-changeme}"
PPTP_DNS1="${PPTP_DNS1:-1.1.1.1}"
PPTP_DNS2="${PPTP_DNS2:-8.8.8.8}"

cat > /etc/pptpd.conf <<EOF
option /etc/ppp/pptpd-options
logwtmp
localip ${PPTP_LOCAL_IP}
remoteip ${PPTP_REMOTE_IP_RANGE}
EOF

cat > /etc/ppp/pptpd-options <<EOF
name pptpd
refuse-pap
refuse-chap
refuse-mschap
require-mschap-v2
require-mppe-128
ms-dns ${PPTP_DNS1}
ms-dns ${PPTP_DNS2}
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

iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i ppp+ -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o ppp+ -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "Starting pptpd..."
exec pptpd --fg
