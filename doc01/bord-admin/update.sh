#!/bin/sh
# Pull the latest bord admin image and restart only if it changed.
# Run by bord-admin-update.timer every 5 minutes.
set -eu
cd /opt/bord-admin
docker compose pull --quiet
docker compose up -d 2>&1 | grep -E "Recreat|Creat|Start" || true
docker image prune -f --filter "label=org.opencontainers.image.source=https://github.com/Webtamu/bord" >/dev/null
