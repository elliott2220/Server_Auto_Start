#!/bin/bash
# Backrest pre-backup hook — infrastructure group
# Stops containers before snapshot
# Note: cloudflared is intentionally skipped — stopping it kills the tunnel

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:$PATH"

is_running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

echo "=== pre-infrastructure: stopping containers ==="

for c in portainer wud netdata speedtest; do
    if is_running "$c"; then
        echo "Stopping $c"
        docker stop "$c"
    fi
done

echo "=== pre-infrastructure: done ==="
