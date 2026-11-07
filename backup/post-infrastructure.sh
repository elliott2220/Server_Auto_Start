#!/bin/bash
# Backrest post-backup hook — infrastructure group
# Restarts containers after snapshot

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:$PATH"

echo "=== post-infrastructure: restarting containers ==="

for c in portainer wud netdata speedtest; do
    docker start "$c" 2>/dev/null && echo "Started $c" || true
done

echo "=== post-infrastructure: done ==="
