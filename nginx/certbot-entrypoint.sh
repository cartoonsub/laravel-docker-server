#!/bin/sh
set -eu

DOMAIN="${SERVER_NAME:?SERVER_NAME environment variable is required}"
EMAIL="${CERTBOT_EMAIL:?CERTBOT_EMAIL environment variable is required}"
WEBROOT="/var/www/certbot"

if [ "$DOMAIN" = "localhost" ] || [ "$DOMAIN" = "yourdomain.com" ]; then
    echo "SERVER_NAME is not a real domain (${DOMAIN}), certbot disabled"
    exit 0
fi

trap 'exit 0' TERM INT

# Give nginx time to start and render its config before the first attempt.
sleep 10

# Initial issuance: retry every 5 minutes until it succeeds.
while [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; do
    echo "Requesting initial certificate for ${DOMAIN}"
    if certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" \
        --email "$EMAIL" --agree-tos --no-eff-email --non-interactive; then
        echo "Certificate issued for ${DOMAIN}"
        break
    fi
    echo "Initial issuance failed, retrying in 5 minutes"
    sleep 300 &
    wait $! || true
done

# Renewal loop: certbot renew is a no-op until the certificate is close to expiry.
while :; do
    sleep 43200 &
    wait $! || true

    certbot renew --webroot -w "$WEBROOT" --quiet \
        || echo "Renewal failed, will retry in 12h"
done
