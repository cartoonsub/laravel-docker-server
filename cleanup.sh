#!/bin/bash
set -eu

echo "Starting Docker cleanup..."

# NOTE: `docker volume prune` is intentionally NOT used here.
# It deletes all unused volumes, including mariadb_data, if the DB container
# happens to be stopped at that moment (restart, backup, image update).
# That would destroy the database irreversibly.

docker system prune -f
docker image prune -a -f

echo "Cleanup completed!"

# Example crontab entry to run this script every Sunday at midnight
# 0 0 * * 0 /root/docker-cleanup.sh >> /var/log/docker-cleanup.log 2>&1
