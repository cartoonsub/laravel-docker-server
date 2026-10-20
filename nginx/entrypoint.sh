#!/bin/sh
set -eu

DOMAIN="${SERVER_NAME:?SERVER_NAME environment variable is required}"
CERT_DIR="/etc/nginx/ssl/active"
LE_DIR="/etc/letsencrypt/live/${DOMAIN}"

render_templates() {
    mkdir -p /etc/nginx/conf.d
    # Drop the stock default server from the base image, otherwise it
    # conflicts with our rendered server blocks.
    rm -f /etc/nginx/conf.d/default.conf
    for tpl in /etc/nginx/templates/*.template; do
        [ -e "$tpl" ] || continue
        out="/etc/nginx/conf.d/$(basename "$tpl" .template)"
        envsubst '${SERVER_NAME}' < "$tpl" > "$out"
        echo "Rendered $out"
    done
}

# Copy certificates from the certbot volume into the directory nginx reads.
# Returns 0 only when the files actually changed (so we reload only then).
sync_certs() {
    [ -f "${LE_DIR}/fullchain.pem" ] || return 1
    [ -f "${LE_DIR}/privkey.pem" ] || return 1

    if cmp -s "${LE_DIR}/fullchain.pem" "${CERT_DIR}/fullchain.pem" 2>/dev/null &&
       cmp -s "${LE_DIR}/privkey.pem" "${CERT_DIR}/privkey.pem" 2>/dev/null; then
        return 1
    fi

    cp -f "${LE_DIR}/fullchain.pem" "${CERT_DIR}/fullchain.pem"
    cp -f "${LE_DIR}/privkey.pem" "${CERT_DIR}/privkey.pem"
    echo "Certificates updated from Let's Encrypt"
    return 0
}

render_templates
mkdir -p "$CERT_DIR"

if ! sync_certs; then
    if [ ! -f "${CERT_DIR}/fullchain.pem" ]; then
        echo "No certificate available yet, generating temporary self-signed certificate for ${DOMAIN}"
        openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
            -keyout "${CERT_DIR}/privkey.pem" \
            -out "${CERT_DIR}/fullchain.pem" \
            -subj "/CN=${DOMAIN}"
    fi
fi

nginx -g 'daemon off;' &
NGINX_PID=$!

cleanup() {
    kill -TERM "$NGINX_PID" 2>/dev/null || true
    wait "$NGINX_PID" 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

# Check for renewed certificates every minute and reload nginx when they change.
while :; do
    sleep 60 &
    wait $! || true

    if sync_certs; then
        if nginx -t; then
            nginx -s reload
            echo "nginx reloaded with new certificates"
        else
            echo "nginx config test failed, skipping reload" >&2
        fi
    fi
done
