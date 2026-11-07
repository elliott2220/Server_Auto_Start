#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  Ready-made Backrest setup: repository on the NAS + a weekly plan that covers
#  everything needed to rebuild this machine. Skipped if a config already exists
#  (e.g. it was just restored from a backup).  Sourced by install.sh.
# ─────────────────────────────────────────────────────────────────────────────

backrest_default_config() {
    local cfg="${DOCKERPATH}/cloudservices/backrest/config/config.json"
    if [[ -f "$cfg" ]]; then
        info "Backrest already has a config — leaving it alone."
        return 0
    fi

    echo ""
    echo "${BOLD}── Backrest: default backup plan ──${RESET}"
    ask "Backup repository folder (on the NAS)" BACKUP_REPO "/mnt/Backups/Docker/$(hostname -s)"
    ask "Backup time, 24h (weekly, Sunday)" BACKUP_HOUR "3"
    echo "  healthchecks.io ping URL gives you an alert when a backup FAILS or never runs."
    read -r -p "  healthchecks.io URL (blank to skip): " HC_URL

    local repo_pw
    repo_pw="${RESTIC_PASSWORD:-}"
    if [[ -z "$repo_pw" ]]; then
        repo_pw=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
        GENERATED_PW=1
    fi

    sudo mkdir -p "$BACKUP_REPO"
    if [[ ! -f "$BACKUP_REPO/config" ]]; then
        RESTIC_PASSWORD="$repo_pw" restic init --repo "$BACKUP_REPO" >/dev/null \
            || { warn "Could not create the repository at $BACKUP_REPO (is the NAS mounted?)"; return 1; }
        info "created restic repository at $BACKUP_REPO"
    fi

    sudo mkdir -p "$(dirname "$cfg")"
    BR_REPO="$BACKUP_REPO" BR_PW="$repo_pw" BR_HOUR="$BACKUP_HOUR" BR_HC="${HC_URL:-}" \
    BR_DOCKER="$DOCKERPATH" BR_HOST="$(hostname -s)" BR_OUT="$cfg" python3 - <<'PY'
import json, os
e = os.environ
plan = {
    "id": "Weekly",
    "repo": "NAS",
    # Everything needed to rebuild: app configs, Portainer stacks, the Backrest
    # config (holds this repo's password), the installer's saved answers
    # ($DOCKERPATH/homelab.conf) and the secrets folder.
    "paths": [e["BR_DOCKER"], "/srv/kona-secrets"],
    "excludes": [
        "**/Plex Media Server/Cache", "**/Plex Media Server/Logs",
        "**/Plex Media Server/Crash Reports", "**/Plex Media Server/Codecs",
        "**/tdarr/server/Tdarr/DB2/JobReports", "**/tdarr/logs",
        e["BR_DOCKER"] + "/cloudservices/backrest/cache",
        e["BR_DOCKER"] + "/cloudservices/backrest/tmp",
        "**/.cache",
    ],
    "schedule": {"cron": "0 %s * * 0" % e["BR_HOUR"], "clock": "CLOCK_LOCAL"},
    "retention": {"policyTimeBucketed": {"daily": 14, "weekly": 8, "monthly": 12}},
    "hooks": [],
}
if e["BR_HC"]:
    plan["hooks"].append({
        "actionHealthchecks": {"webhookUrl": e["BR_HC"], "template": "{{ .Summary }}"},
        "conditions": ["CONDITION_SNAPSHOT_START", "CONDITION_SNAPSHOT_SUCCESS", "CONDITION_ANY_ERROR"],
    })
cfg = {
    "modno": 1, "version": 4, "instance": e["BR_HOST"],
    "repos": [{
        "id": "NAS", "uri": e["BR_REPO"], "password": e["BR_PW"],
        "prunePolicy": {"schedule": {"cron": "0 0 1 * *", "clock": "CLOCK_LAST_RUN_TIME"}, "maxUnusedPercent": 10},
        "checkPolicy": {"schedule": {"cron": "0 0 1 * *", "clock": "CLOCK_LAST_RUN_TIME"}},
        "commandPrefix": {},
    }],
    "plans": [plan],
    "auth": {"disabled": True},
}
with open(e["BR_OUT"], "w") as f:
    json.dump(cfg, f, indent=2)
os.chmod(e["BR_OUT"], 0o600)
PY
    info "Backrest plan written (weekly, Sundays ${BACKUP_HOUR}:00)"

    echo ""
    echo "  ${RED}${BOLD}┌─ SAVE THIS PASSWORD NOW ───────────────────────────────────┐${RESET}"
    echo "  ${RED}${BOLD}│${RESET} Backup repository password:  ${BOLD}${repo_pw}${RESET}"
    echo "  ${RED}${BOLD}│${RESET} Without it the backup on the NAS CANNOT be opened — not by"
    echo "  ${RED}${BOLD}│${RESET} you, not by anyone. Put it in your password manager now."
    echo "  ${RED}${BOLD}└────────────────────────────────────────────────────────────┘${RESET}"
    local ack=""
    while [[ "$ack" != "saved" ]]; do read -r -p "  Type 'saved' once it is stored somewhere safe: " ack; done
}
