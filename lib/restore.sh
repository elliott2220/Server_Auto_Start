#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  Restore from a restic backup.
#    restore_prompt  – ask where the backup is (runs early, nothing is changed)
#    restore_run     – restore it (runs after Docker/NFS are ready, before the
#                      apps are configured, so restored configs win)
#    restore_extras  – optional follow-ups: Portainer stacks, Immich photos
#  Sourced by install.sh.
# ─────────────────────────────────────────────────────────────────────────────

RESTORE_ENABLED=0
RESTORE_MOUNT=""

restore_prompt() {
    echo ""
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│                    Restore from a backup?                    │"
    echo "└──────────────────────────────────────────────────────────────┘"
    echo "  Use this when replacing hardware. It restores your app configs"
    echo "  (Plex, Sonarr, Radarr, Tdarr, Portainer, secrets...) from a restic"
    echo "  repository, e.g. the one Backrest writes to your NAS."
    yesno "Restore a backup now?" n || return 0

    echo ""
    echo "  Where is the restic repository?"
    echo "    1) NFS share        (e.g. 192.168.50.50:/volume1/Backups)"
    echo "    2) Folder on this machine  (USB drive, or an already-mounted NAS path)"
    echo "    3) Remote restic URL       (b2:bucket:path, sftp:user@host:/path, s3:..., rest:...)"
    local choice sub
    read -r -p "  Choose 1-3: " choice
    case "$choice" in
        1)
            read -r -p "  NFS export (host:/path): " RESTORE_NFS
            read -r -p "  Repository folder inside that share [Docker/Franklin]: " sub
            RESTORE_REPO_SUB="${sub:-Docker/Franklin}"
            RESTORE_KIND=nfs ;;
        2)
            read -r -p "  Full path of the repository folder: " RESTORE_REPO
            RESTORE_KIND=local ;;
        3)
            read -r -p "  Repository URL: " RESTORE_REPO
            RESTORE_KIND=remote
            if [[ "$RESTORE_REPO" == b2:* ]]; then
                read -r -p "  B2 key ID: " B2_ACCOUNT_ID
                read -rs -p "  B2 application key: " B2_ACCOUNT_KEY; echo
                export B2_ACCOUNT_ID B2_ACCOUNT_KEY
            fi ;;
        *) echo "  Invalid choice — skipping restore."; return 0 ;;
    esac

    if [[ -z "${RESTIC_PASSWORD:-}" ]]; then
        read -rs -p "  Repository password: " RESTIC_PASSWORD; echo
        export RESTIC_PASSWORD
    fi
    RESTORE_ENABLED=1
}

_restore_cleanup() {
    if [[ -n "$RESTORE_MOUNT" ]] && mountpoint -q "$RESTORE_MOUNT"; then
        sudo umount "$RESTORE_MOUNT" 2>/dev/null || true
        sudo rmdir "$RESTORE_MOUNT" 2>/dev/null || true
    fi
}

restore_run() {
    [[ "$RESTORE_ENABLED" == "1" ]] || return 0
    echo ""
    echo "${BOLD}── Restoring backup ──${RESET}"
    command -v restic >/dev/null || { echo "restic is not installed"; return 1; }

    case "$RESTORE_KIND" in
        nfs)
            sudo dnf -y install nfs-utils >/dev/null
            RESTORE_MOUNT=$(mktemp -d /mnt/homelab-restore.XXXXXX)
            sudo mount -t nfs -o ro,nfsvers=3 "$RESTORE_NFS" "$RESTORE_MOUNT" \
                || { echo "Could not mount $RESTORE_NFS"; return 1; }
            export RESTIC_REPOSITORY="$RESTORE_MOUNT/$RESTORE_REPO_SUB" ;;
        *) export RESTIC_REPOSITORY="$RESTORE_REPO" ;;
    esac
    trap '_restore_cleanup; cleanup' EXIT

    # Never guess: prove the password and repo work before touching anything.
    if ! restic snapshots --compact --latest 5 2>/tmp/restic-err; then
        echo "${RED}Could not open the repository.${RESET}"
        cat /tmp/restic-err; rm -f /tmp/restic-err
        echo "Check the path and password. Nothing was changed."
        return 1
    fi
    rm -f /tmp/restic-err

    local snap
    read -r -p "  Snapshot to restore [latest]: " snap
    snap="${snap:-latest}"

    echo "  Preview (nothing is written yet):"
    restic restore "$snap" --target / --dry-run 2>&1 | tail -3 | sed 's/^/    /'

    echo ""
    warn "This writes into / (for example ${DOCKERPATH:-/opt/docker} and /srv) and overwrites existing files."
    yesno "Restore snapshot '$snap' now?" n || { echo "  Restore skipped."; _restore_cleanup; return 0; }

    restic restore "$snap" --target / --verify 2>&1 | tail -5 | sed 's/^/    /'
    echo "  ${GREEN}Restore finished.${RESET}"
    _restore_cleanup
    unset RESTIC_REPOSITORY
    RESTORED=1
}

# Re-create the containers that were managed from Portainer (e.g. your Kona
# apps). The restore brings back Portainer's stack folders; here we start them.
restore_extras() {
    [[ "${RESTORED:-0}" == "1" ]] || return 0
    local base="${DOCKERPATH}/infrastructure/portainer/data/compose"

    if [[ -d "$base" ]]; then
        echo ""
        echo "${BOLD}── Portainer stacks found in the backup ──${RESET}"
        local d n f name
        for d in "$base"/*/; do
            n=$(basename "$d")
            f=""
            for cand in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
                [[ -f "$d$cand" ]] && { f="$cand"; break; }
            done
            [[ -n "$f" ]] || continue
            name=$(grep -m1 -E '^name:' "$d$f" 2>/dev/null | awk '{print $2}' | tr -d '"' || true)
            name="${name:-stack$n}"
            if is_selected immich && grep -qi 'immich' "$d$f"; then
                warn "Stack $n ($name) is Immich, which you selected in the menu — skipping to avoid a clash."
                continue
            fi
            yesno "Start stack $n ($name)?" y || continue
            local envarg=()
            [[ -f "$d/stack.env" ]] && envarg=(--env-file "$d/stack.env")
            sudo docker compose --project-directory "$d" -p "$name" "${envarg[@]}" -f "$d$f" up -d --build \
                || warn "stack $n failed to start — open Portainer or run docker compose logs in $d"
        done
    fi

    # Photos: pull them back from Backblaze using the rclone.conf in the backup.
    if is_selected immich && [[ -f /srv/kona-secrets/rclone.conf ]]; then
        echo ""
        echo "${BOLD}── Immich photos ──${RESET}"
        local bucket
        read -r -p "  B2 bucket holding the photo backup [kona-immich-backup]: " bucket
        bucket="${bucket:-kona-immich-backup}"
        if yesno "Download photos from b2:${bucket} into ${IMMICH_UPLOAD_LOCATION}? (can be 100+ GB)" n; then
            sudo rclone --config /srv/kona-secrets/rclone.conf copy "b2:${bucket}" "${IMMICH_UPLOAD_LOCATION}" \
                --transfers 8 --checkers 16 --stats-one-line --stats 1m
            echo "  Then in Immich (first-run screen) choose 'Restore from backup' and pick the newest database dump."
        fi
    fi
}
