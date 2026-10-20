#!/bin/sh
set -eu

DOMAIN="${SERVER_NAME:?SERVER_NAME environment variable is required}"
EMAIL="${CERTBOT_EMAIL:?CERTBOT_EMAIL environment variable is required}"
WEBROOT="/var/www/certbot"

case "$DOMAIN" in
    localhost|127.0.0.1|example.com|www.example.com|yourdomain.com|www.yourdomain.com)
        echo "SERVER_NAME is a placeholder (${DOMAIN}), certbot disabled"
        exit 0
        ;;
esac

trap 'exit 0' TERM INT

# Give nginx time to start and render its config before the first attempt.
sleep 10

# Initial issuance with exponential backoff (5m -> 10m -> 20m -> 40m -> 1h, capped).
# Prevents hammering Let's Encrypt when DNS or the firewall is misconfigured.
DELAY=300
while [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; do
    echo "Requesting initial certificate for ${DOMAIN}"
    if certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" \
        --email "$EMAIL" --agree-tos --no-eff-email --non-interactive; then
        echo "Certificate issued for ${DOMAIN}"
        break
    fi
    echo "Initial issuance failed, retrying in $((DELAY / 60)) minutes"
    sleep "$DELAY" &
    wait $! || true
    if [ "$DELAY" -lt 3600 ]; then
        DELAY=$((DELAY * 2))
        [ "$DELAY" -gt 3600 ] && DELAY=3600
    fi
done

# Renewal loop: certbot renew is a no-op until the certificate is close to expiry.
while :; do
    sleep 43200 &
    wait $! || true

    certbot renew --webroot -w "$WEBROOT" --quiet \
        || echo "Renewal failed, will retry in 12h"
done
