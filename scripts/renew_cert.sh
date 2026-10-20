#!/usr/bin/env sh
# Manual certificate renewal (the certbot container renews automatically,
# this script is only for forcing a renewal / debugging).
set -eu

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$PROJECT_DIR"

docker compose exec -T certbot certbot renew --webroot -w /var/www/certbot --force-renewal

# nginx reloads itself when it detects changed certificates,
# but reload explicitly to apply immediately.
docker compose exec -T nginx nginx -t
docker compose exec -T nginx nginx -s reload
