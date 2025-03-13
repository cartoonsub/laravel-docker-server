#!/bin/bash
echo "Starting Docker cleanup..."
docker system prune -f
docker image prune -a -f
docker volume prune -f
echo "Cleanup completed!"

# Example crontab entry to run this script every Sunday at midnight
# 0 0 * * 0 /root/docker-cleanup.sh >> /var/log/docker-cleanup.log 2>&1
