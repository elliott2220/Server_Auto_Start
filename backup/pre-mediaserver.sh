#!/bin/bash
# Backrest pre-backup hook — mediaserver group
# Stops containers before snapshot

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:$PATH"

is_running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

echo "=== pre-mediaserver: stopping containers ==="

# Stop dependents before gluetun (qbittorrent uses gluetun's network namespace)
for c in sonarr radarr prowlarr nzbget qbittorrent tdarr_node tdarr_server uptime-kuma plex seerr gluetun; do
    is_running "$c" && echo "Stopping $c" && docker stop "$c"
done

echo "=== pre-mediaserver: done ==="
