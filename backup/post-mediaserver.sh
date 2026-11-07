#!/bin/bash
# Backrest post-backup hook — mediaserver group
# Restarts containers after snapshot

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:$PATH"

echo "=== post-mediaserver: restarting containers ==="

# Start gluetun first — qbittorrent depends on its network namespace
docker start gluetun 2>/dev/null && echo "Started gluetun" || true

sleep 5

for c in sonarr radarr prowlarr nzbget qbittorrent tdarr_node tdarr_server uptime-kuma plex seerr; do
    docker start "$c" 2>/dev/null && echo "Started $c" || true
done

echo "=== post-mediaserver: done ==="
