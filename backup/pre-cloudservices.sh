#!/bin/bash
# Backrest pre-backup hook — cloudservices group
# Dumps databases and stops containers before snapshot

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/backup.conf"

DUMP_DIR="${DOCKERPATH}/cloudservices/backup/dumps"
mkdir -p "$DUMP_DIR"

is_running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

echo "=== pre-cloudservices: cleaning old dumps ==="
find "$DUMP_DIR" -name "*.sql" -mtime +2 -delete

echo "=== pre-cloudservices: dumping databases ==="

if is_running immich_postgres; then
    echo "Dumping Immich database"
    docker exec immich_postgres pg_dumpall -U immich > "${DUMP_DIR}/immich_db_$(date +%Y%m%d_%H%M%S).sql"
fi

if is_running seafile-db; then
    echo "Dumping Seafile database"
    docker exec seafile-db mysqldump --all-databases -uroot -p"${SEAFILE_DB_PASSWORD}" \
        > "${DUMP_DIR}/seafile_db_$(date +%Y%m%d_%H%M%S).sql"
fi

echo "=== pre-cloudservices: stopping containers ==="

for c in immich_server immich_machine_learning immich_redis immich_postgres \
          seafile seafile-memcached seafile-db \
          vaultwarden; do
    is_running "$c" && echo "Stopping $c" && docker stop "$c"
done

echo "=== pre-cloudservices: done ==="
