FROM alpine:3.19

RUN apk add --no-cache pptpd iptables bash

COPY scripts/pptpd-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 1723

ENTRYPOINT ["/entrypoint.sh"]
