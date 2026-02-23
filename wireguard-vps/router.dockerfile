FROM alpine:3.19

RUN apk add --no-cache iptables iproute2 bash wireguard-tools

COPY scripts/router-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
