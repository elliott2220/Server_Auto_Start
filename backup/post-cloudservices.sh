#!/bin/bash
# Backrest post-backup hook — cloudservices group
# Restarts containers after snapshot

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:$PATH"

echo "=== post-cloudservices: restarting containers ==="

# DBs and independent services first
for c in immich_postgres seafile-db vaultwarden; do
    docker start "$c" 2>/dev/null && echo "Started $c" || true
done

sleep 5

# Apps that depend on DBs
for c in immich_redis immich_server immich_machine_learning \
          seafile-memcached seafile; do
    docker start "$c" 2>/dev/null && echo "Started $c" || true
done

echo "=== post-cloudservices: done ==="
