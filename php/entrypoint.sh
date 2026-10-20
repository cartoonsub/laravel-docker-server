#!/bin/sh
set -eu

# Bind-mounting the project over /var/www/html hides everything created at
# build time, so permissions must be fixed here, at container start.
fix_permissions() {
    [ -d /var/www/html ] || return 0

    mkdir -p \
        /var/www/html/storage/app/public \
        /var/www/html/storage/framework/cache \
        /var/www/html/storage/framework/sessions \
        /var/www/html/storage/framework/views \
        /var/www/html/storage/logs \
        /var/www/html/bootstrap/cache

    chown -R www-data:www-data \
        /var/www/html/storage \
        /var/www/html/bootstrap/cache 2>/dev/null || true

    chmod -R ug+rwX \
        /var/www/html/storage \
        /var/www/html/bootstrap/cache 2>/dev/null || true
}

fix_permissions

# Start the Laravel scheduler as www-data (not root), so files it creates
# in storage/ stay owned by www-data.
if [ "${RUN_CRON:-1}" = "1" ] && command -v cron >/dev/null 2>&1; then
    if [ -f /usr/local/etc/laravel-crontab ]; then
        crontab -u www-data /usr/local/etc/laravel-crontab || true
    fi
    cron
fi

# php-fpm must be PID 1 so the container stops correctly and restarts on crash.
exec "$@"
