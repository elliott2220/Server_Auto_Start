#!/bin/bash

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────
#  Terminal colors
# ─────────────────────────────────────────────
BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'
YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; RESET=$'\033[0m'

# ─────────────────────────────────────────────
#  Saved config (paths and domain name)
# ─────────────────────────────────────────────
CONFIG_FILE="${HOME}/.homelab"
[[ -f "$CONFIG_FILE" ]] || { [[ -f "${HOME}/.privatecloud" ]] && CONFIG_FILE="${HOME}/.privatecloud"; }
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ─────────────────────────────────────────────
#  Command-line flags
# ─────────────────────────────────────────────
PRESELECT=""
FORCE_TEXT=0
usage() {
    cat <<'USAGE'
Usage: install.sh [--apps a,b,c] [--list] [--help]

  --apps a,b,c   pre-tick these apps in the menu (names from apps.txt)
  --list         print every app you can install, then exit
  --text         use the plain numbered menu instead of the checklist
  --help         this text
USAGE
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apps) PRESELECT="${2:-}"; shift 2 ;;
        --list) grep -vE '^[[:space:]]*(#|$)' "$SCRIPT_DIR/apps.txt" | awk -F'|' '{printf "  %-16s %-14s %s\n",$1,$2,$3}'; exit 0 ;;
        --text) FORCE_TEXT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# Prompt with a saved/default value — press Enter to accept, or type to override
ask() {
    local prompt="$1" varname="$2" fallback="${3:-}" current="${!2:-}"
    local effective="${current:-$fallback}"
    if [[ -n "$effective" ]]; then
        read -r -p "$prompt [$effective]: " input
        if [[ -n "$input" ]]; then
            printf -v "$varname" '%s' "$input"
        else
            printf -v "$varname" '%s' "$effective"
        fi
    else
        read -r -p "$prompt: " "$varname"
    fi
}

make_dir() {
    sudo mkdir -p "$1"
    sudo chown "${PUID}:${PGID}" "$(dirname "$1")" "$1"
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
DOCKERPATH="${DOCKERPATH}"
TZ="${TZ}"
DOMAINNAME="${DOMAINNAME:-}"
PROCESSPATH="${PROCESSPATH:-}"
MEDIAPATH="${MEDIAPATH:-}"
GLUETUN_VPN_TYPE="${GLUETUN_VPN_TYPE:-wireguard}"
BACKUPPATH="${BACKUPPATH:-}"
BOOKSPATH="${BOOKSPATH:-}"
GRIMMORY_DB_PASSWORD="${GRIMMORY_DB_PASSWORD:-}"
PAPERLESS_DB_PASSWORD="${PAPERLESS_DB_PASSWORD:-}"
PAPERLESS_SECRET_KEY="${PAPERLESS_SECRET_KEY:-}"
IMMICH_DB_PASSWORD="${IMMICH_DB_PASSWORD:-}"
IMMICH_UPLOAD_LOCATION="${IMMICH_UPLOAD_LOCATION:-}"
IMMICH_DB_LOCATION="${IMMICH_DB_LOCATION:-}"
NAS_HOST="${NAS_HOST:-}"
NFS_MAPS="${NFS_MAPS:-}"
EOF
    chmod 600 "$CONFIG_FILE"
    # A copy lives inside DOCKERPATH so the backup carries it: generated secrets
    # (database passwords) must match the restored databases after a rebuild.
    if [[ -d "${DOCKERPATH:-}" ]]; then
        sudo cp "$CONFIG_FILE" "${DOCKERPATH}/homelab.conf" && sudo chmod 600 "${DOCKERPATH}/homelab.conf"
    fi
}

# Remove .env on exit (success or failure)
cleanup() {
    rm -f "$SCRIPT_DIR/.env"
}
trap cleanup EXIT

# ─────────────────────────────────────────────
#  Service selection menu
# ─────────────────────────────────────────────
# Menu is built from apps.txt — add a line there to offer a new program.
SERVICES=(); LABELS=(); SVC_GROUPS=(); SVC_PORTS=(); SVC_PATHS=(); SVC_PROFILES=(); SVC_DIRS=()
while IFS='|' read -r _n _g _l _p _u _pr _d; do
    [[ -z "${_n// }" || "$_n" == \#* ]] && continue
    SERVICES+=("$_n"); SVC_GROUPS+=("$_g"); LABELS+=("$_l")
    SVC_PORTS+=("$_p"); SVC_PATHS+=("$_u"); SVC_PROFILES+=("${_pr:-$_n}"); SVC_DIRS+=("$_d")
done < "$SCRIPT_DIR/apps.txt"

# Default: nothing ticked (use --apps a,b,c to pre-tick). Cloudflared and
# Portainer are handled separately.
SELECTED=()
for _n in "${SERVICES[@]}"; do
    if [[ ",${PRESELECT}," == *",${_n},"* ]]; then SELECTED+=(1); else SELECTED+=(0); fi
done

show_menu() {
    echo ""
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│             Homelab — Select Services                         │"
    echo "├──────────────────────────────────────────────────────────────┤"
    local last_group=""
    for i in "${!SERVICES[@]}"; do
        local group="${SVC_GROUPS[$i]}"
        if [[ "$group" != "$last_group" ]]; then
            printf "│                                                              │\n"
            printf "│  ${CYAN}${BOLD}── %-55s${RESET}  │\n" "$group"
            last_group="$group"
        fi
        local mark
        if [[ "${SELECTED[$i]}" == "1" ]]; then
            mark="${GREEN}[x]${RESET}"
            printf "│  %2d) %s  %-50s │\n" "$((i+1))" "$mark" "${LABELS[$i]}"
        else
            mark="${DIM}[ ]${RESET}"
            printf "${DIM}│  %2d)${RESET} %s  ${DIM}%-50s │${RESET}\n" "$((i+1))" "$mark" "${LABELS[$i]}"
        fi
    done
    echo "│                                                              │"
    echo "└──────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  Enter number(s) to toggle (e.g. '3' or '1 4 7')"
    echo "  'a' = select all  |  'n' = deselect all  |  'c' = clear saved config  |  'go' = confirm"
}

# Checklist UI (arrow keys + space) when whiptail is available; otherwise the
# numbered text menu below is used. Pass --text to force the text menu.
UI_DONE=0
whiptail_menu() {
    command -v whiptail >/dev/null 2>&1 && [[ -t 0 && -t 1 ]] || return 1
    local args=() i state out
    for i in "${!SERVICES[@]}"; do
        state=OFF; [[ "${SELECTED[$i]}" == "1" ]] && state=ON
        args+=("${SERVICES[$i]}" "${SVC_GROUPS[$i]} — ${LABELS[$i]}" "$state")
    done
    out=$(whiptail --title "Homelab — choose what to install" \
        --checklist "SPACE = tick/untick   ENTER = continue   (re-run any time to add more)" \
        24 90 16 "${args[@]}" 3>&1 1>&2 2>&3) || return 1
    SELECTED=()
    for i in "${!SERVICES[@]}"; do
        if [[ " ${out//\"/} " == *" ${SERVICES[$i]} "* ]]; then SELECTED+=(1); else SELECTED+=(0); fi
    done
    UI_DONE=1
}
[[ "$FORCE_TEXT" == "1" ]] || whiptail_menu || true

while [[ "$UI_DONE" != "1" ]]; do
    show_menu
    read -rp "  > " input
    case "$input" in
        go) break ;;
        a) SELECTED=(); for _ in "${SERVICES[@]}"; do SELECTED+=(1); done ;;
        n) SELECTED=(); for _ in "${SERVICES[@]}"; do SELECTED+=(0); done ;;
        c) rm -f "$CONFIG_FILE" && echo "  Saved config cleared." ;;
        *)
            for num in $input; do
                if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#SERVICES[@]} )); then
                    idx=$((num - 1))
                    [[ "${SELECTED[$idx]}" == "1" ]] && SELECTED[$idx]=0 || SELECTED[$idx]=1
                else
                    printf "  ${RED}Invalid selection: %s (valid range: 1-%d)${RESET}\n" "$num" "${#SERVICES[@]}"
                fi
            done
            ;;
    esac
done

# Returns 0 (true) if the named service is selected
is_selected() {
    for i in "${!SERVICES[@]}"; do
        if [[ "${SERVICES[$i]}" == "$1" && "${SELECTED[$i]}" == "1" ]]; then
            return 0
        fi
    done
    return 1
}

# Builds --profile args for given service names
profile_args() {
    local args=""
    for svc in "$@"; do
        is_selected "$svc" && args="$args --profile $svc"
    done
    echo "$args"
}

# ─────────────────────────────────────────────
#  Collect credentials (only what's needed)
# ─────────────────────────────────────────────
PUID=$(id -u)
PGID=$(id -g)

echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│                     Required Settings                        │"
echo "└──────────────────────────────────────────────────────────────┘"

ask "Path for Docker data" DOCKERPATH "/opt/docker"
make_dir "$DOCKERPATH"

ask "Timezone" TZ "America/Denver"

# ─────────────────────────────────────────────
#  Prepare the machine, install Docker, optionally restore a backup
#  (done now so restored configs are in place BEFORE apps are configured)
# ─────────────────────────────────────────────
source "$SCRIPT_DIR/lib/prep.sh"
source "$SCRIPT_DIR/lib/restore.sh"
source "$SCRIPT_DIR/lib/backrest.sh"
RESTORED=0

restore_prompt
prep_system
bash "$SCRIPT_DIR/docker.sh"
sudo systemctl daemon-reload
sudo systemctl enable --now docker >/dev/null 2>&1 || true
sudo docker network inspect internal >/dev/null 2>&1 || \
    sudo docker network create -d bridge --subnet=172.19.0.0/24 internal
sudo docker network inspect external >/dev/null 2>&1 || \
    sudo docker network create -d bridge --subnet=172.20.0.0/24 external

restore_run
if [[ "$RESTORED" == "1" && -f "${DOCKERPATH}/homelab.conf" ]]; then
    # Reuse the saved answers (esp. database passwords) so they match the restored data.
    _keep_dockerpath="$DOCKERPATH"; _keep_tz="$TZ"
    source "${DOCKERPATH}/homelab.conf"
    DOCKERPATH="$_keep_dockerpath"; TZ="$_keep_tz"
    echo "  Loaded saved answers from the backup."
fi

if is_selected duckdns || is_selected speedtest; then
    ask "Domain name" DOMAINNAME
fi

if is_selected nzbget || is_selected sonarr || is_selected radarr || is_selected tdarr || is_selected qbittorrentvpn; then
    ask "Path for temp processing" PROCESSPATH "/opt/processing"
    make_dir "$PROCESSPATH"
fi

if is_selected nzbget || is_selected sonarr || is_selected radarr || is_selected tdarr || is_selected plex || is_selected qbittorrentvpn; then
    ask "Path for media (NFS shares are mounted beneath this)" MEDIAPATH "/mnt/Media"
    make_dir "$MEDIAPATH"
fi

if is_selected audiobookshelf || is_selected grimmory || is_selected shelfmark; then
    ask "Path for books & audiobooks" BOOKSPATH "${MEDIAPATH:-/mnt/Media}/books"
    make_dir "$BOOKSPATH"
fi

save_config

if is_selected plex; then
    echo "Plex claim token (from plex.tv/claim):"
    read -r PLEXCLAIM
fi


if is_selected duckdns; then
    echo "DuckDNS token:"
    read -rs DUCKDNSTOKEN
    echo
fi

if is_selected qbittorrentvpn; then
    _detected_subnet=$(ip route | awk '/proto kernel/ && /src/ {split($1,a,"."); printf "%s.%s.%s.0/%s\n", a[1],a[2],a[3], substr($1,index($1,"/")+1)}' | head -1)
    ask "Local subnet for qBittorrent auth bypass (CIDR)" QBIT_SUBNET "${_detected_subnet}"
    ask "VPN type for qBittorrent+VPN (wireguard/openvpn)" GLUETUN_VPN_TYPE "wireguard"
    if [[ "$GLUETUN_VPN_TYPE" == "wireguard" ]]; then
        make_dir "${DOCKERPATH}/mediaserver/gluetun/wireguard"
    else
        make_dir "${DOCKERPATH}/mediaserver/gluetun"
        echo "OpenVPN username:"
        read -r OPENVPN_USER
        echo "OpenVPN password:"
        read -rs OPENVPN_PASSWORD
        echo
        echo "Paste your OpenVPN config file contents, then press Ctrl+D on a new line (config must use an IP address, not a hostname):"
        _ovpn_content=$(cat)
        if [[ -z "$_ovpn_content" ]]; then
            echo "Warning: OpenVPN config is empty. You must place a valid config at ${DOCKERPATH}/mediaserver/gluetun/custom.conf before starting gluetun."
        else
            printf '%s\n' "$_ovpn_content" > "${DOCKERPATH}/mediaserver/gluetun/custom.conf"
            echo "Config written to ${DOCKERPATH}/mediaserver/gluetun/custom.conf"
        fi
    fi
fi

# Cloudflare Tunnel (optional) — reuse the token from a running container if present
CF_TUNNEL_TOKEN=$(sudo docker inspect cloudflared --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep '^TUNNEL_TOKEN=' | cut -d= -f2- || true)
if [[ -z "$CF_TUNNEL_TOKEN" ]]; then
    echo "Cloudflare Tunnel connection token (press Enter to skip — no tunnel):"
    read -rs CF_TUNNEL_TOKEN
    echo
fi

# Create the data folders declared in apps.txt for every selected app
for i in "${!SERVICES[@]}"; do
    if [[ "${SELECTED[$i]}" == "1" && -n "${SVC_DIRS[$i]}" ]]; then
        IFS=',' read -ra _dirs <<< "${SVC_DIRS[$i]}"
        for _d in "${_dirs[@]}"; do make_dir "${DOCKERPATH}/${_d}"; done
    fi
done

if is_selected immich; then
    # Same layout the original server uses, so a restored photo library drops straight in.
    ask "Path for Immich photo library" IMMICH_UPLOAD_LOCATION "/srv/immich/library"
    ask "Path for Immich database" IMMICH_DB_LOCATION "/srv/immich/postgres"
    make_dir "${IMMICH_UPLOAD_LOCATION}"
    make_dir "${IMMICH_DB_LOCATION}"
    make_dir "${DOCKERPATH}/cloudservices/immich/model-cache"
    if [[ -z "${IMMICH_DB_PASSWORD:-}" ]]; then
        IMMICH_DB_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 24)
    fi
    save_config
fi

if is_selected paperless; then
    for _d in data media export consume db; do make_dir "${DOCKERPATH}/cloudservices/paperless/${_d}"; done
    if [[ -z "${PAPERLESS_DB_PASSWORD:-}" ]]; then
        PAPERLESS_DB_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 24)
        PAPERLESS_SECRET_KEY=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 50)
    fi
    save_config
fi

if is_selected homepage; then
    HOMEPAGE_ALLOWED_HOSTS="$(hostname -I | awk '{print $1}'):3002,$(hostname -s):3002,localhost:3002"
fi

if is_selected vaultwarden; then
    echo "Vaultwarden public URL (e.g. https://vault.yourdomain.com):"
    read -r VAULTWARDEN_DOMAIN
fi

if is_selected seafile; then
    echo "Seafile server hostname (e.g. files.yourdomain.com or your server IP):"
    read -r SEAFILE_HOSTNAME
    ask "Path for Seafile bulk storage" SEAFILE_STORAGE_PATH "${DOCKERPATH}/cloudservices/seafile/storage"
    make_dir "${DOCKERPATH}/cloudservices/seafile/data"
    make_dir "${DOCKERPATH}/cloudservices/seafile/db"
    make_dir "${SEAFILE_STORAGE_PATH}"
    echo "Seafile DB root password:"
    read -rs SEAFILE_DB_ROOT_PASSWORD
    echo
    echo "Seafile admin email:"
    read -r SEAFILE_ADMIN_EMAIL
    echo "Seafile admin password:"
    read -rs SEAFILE_ADMIN_PASSWORD
    echo
fi

if is_selected grimmory; then
    make_dir "${DOCKERPATH}/mediaserver/grimmory/data"
    make_dir "${DOCKERPATH}/mediaserver/grimmory/db"
    if [[ -z "${GRIMMORY_DB_PASSWORD:-}" ]]; then
        GRIMMORY_DB_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 24)
        save_config
    fi
fi

if is_selected backup; then
    echo ""
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│                       Backup Settings                        │"
    echo "└──────────────────────────────────────────────────────────────┘"
    echo "  Hook scripts will be installed to ${DOCKERPATH}/backup/"
    echo "  Configure repos, schedules, retention, and paths in Backrest after install."
    save_config
fi

# ─────────────────────────────────────────────
#  Write .env file
# ─────────────────────────────────────────────
cat > "$SCRIPT_DIR/.env" <<EOF
DOMAINNAME=${DOMAINNAME:-}
DOCKERPATH=${DOCKERPATH}
PROCESSPATH=${PROCESSPATH:-/opt/processing}
MEDIAPATH=${MEDIAPATH:-/mnt/Media}
PLEXCLAIM=${PLEXCLAIM:-}
QBIT_SUBNET=${QBIT_SUBNET:-}
DUCKDNSTOKEN=${DUCKDNSTOKEN:-}
CF_TUNNEL_TOKEN=${CF_TUNNEL_TOKEN:-}
GLUETUN_VPN_TYPE=${GLUETUN_VPN_TYPE:-wireguard}
OPENVPN_USER=${OPENVPN_USER:-}
OPENVPN_PASSWORD=${OPENVPN_PASSWORD:-}
IMMICH_UPLOAD_LOCATION=${IMMICH_UPLOAD_LOCATION:-/srv/immich/library}
IMMICH_DB_LOCATION=${IMMICH_DB_LOCATION:-/srv/immich/postgres}
PAPERLESS_DB_PASSWORD=${PAPERLESS_DB_PASSWORD:-}
PAPERLESS_SECRET_KEY=${PAPERLESS_SECRET_KEY:-}
HOMEPAGE_ALLOWED_HOSTS=${HOMEPAGE_ALLOWED_HOSTS:-localhost:3002}
IMMICH_DB_PASSWORD=${IMMICH_DB_PASSWORD:-}
VAULTWARDEN_DOMAIN=${VAULTWARDEN_DOMAIN:-}
SEAFILE_HOSTNAME=${SEAFILE_HOSTNAME:-}
SEAFILE_STORAGE_PATH=${SEAFILE_STORAGE_PATH:-${DOCKERPATH}/cloudservices/seafile/storage}
SEAFILE_DB_ROOT_PASSWORD=${SEAFILE_DB_ROOT_PASSWORD:-}
SEAFILE_ADMIN_EMAIL=${SEAFILE_ADMIN_EMAIL:-}
SEAFILE_ADMIN_PASSWORD=${SEAFILE_ADMIN_PASSWORD:-}
BOOKSPATH=${BOOKSPATH:-${MEDIAPATH:-/mnt/Media}/books}
GRIMMORY_DB_PASSWORD=${GRIMMORY_DB_PASSWORD:-}
TZ=${TZ}
PUID=${PUID}
PGID=${PGID}
EOF

# ─────────────────────────────────────────────
#  Pre-configure services
# ─────────────────────────────────────────────
if is_selected sonarr && [[ ! -f "${DOCKERPATH}/mediaserver/sonarr/config.xml" ]]; then
    make_dir "${DOCKERPATH}/mediaserver/sonarr"
    SONARR_API_KEY=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 32)
    sudo tee "${DOCKERPATH}/mediaserver/sonarr/config.xml" > /dev/null <<EOF
<Config>
  <BindAddress>*</BindAddress>
  <Port>8989</Port>
  <SslPort>9898</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>True</LaunchBrowser>
  <ApiKey>${SONARR_API_KEY}</ApiKey>
  <AuthenticationMethod>External</AuthenticationMethod>
  <Branch>main</Branch>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <UpdateMechanism>Docker</UpdateMechanism>
  <AnalyticsEnabled>True</AnalyticsEnabled>
  <InstanceName>Sonarr</InstanceName>
</Config>
EOF
    sudo chown "${PUID}:${PGID}" "${DOCKERPATH}/mediaserver/sonarr/config.xml"
fi

if is_selected radarr && [[ ! -f "${DOCKERPATH}/mediaserver/radarr/config.xml" ]]; then
    make_dir "${DOCKERPATH}/mediaserver/radarr"
    RADARR_API_KEY=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 32)
    sudo tee "${DOCKERPATH}/mediaserver/radarr/config.xml" > /dev/null <<EOF
<Config>
  <BindAddress>*</BindAddress>
  <Port>7878</Port>
  <SslPort>7879</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>True</LaunchBrowser>
  <ApiKey>${RADARR_API_KEY}</ApiKey>
  <AuthenticationMethod>External</AuthenticationMethod>
  <Branch>master</Branch>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <UpdateMechanism>Docker</UpdateMechanism>
  <AnalyticsEnabled>True</AnalyticsEnabled>
  <InstanceName>Radarr</InstanceName>
</Config>
EOF
    sudo chown "${PUID}:${PGID}" "${DOCKERPATH}/mediaserver/radarr/config.xml"
fi

if is_selected prowlarr && [[ ! -f "${DOCKERPATH}/mediaserver/prowlarr/config.xml" ]]; then
    make_dir "${DOCKERPATH}/mediaserver/prowlarr"
    PROWLARR_API_KEY=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 32)
    sudo tee "${DOCKERPATH}/mediaserver/prowlarr/config.xml" > /dev/null <<EOF
<Config>
  <BindAddress>*</BindAddress>
  <Port>9696</Port>
  <SslPort>6969</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>True</LaunchBrowser>
  <ApiKey>${PROWLARR_API_KEY}</ApiKey>
  <AuthenticationMethod>External</AuthenticationMethod>
  <Branch>master</Branch>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <UpdateMechanism>Docker</UpdateMechanism>
  <AnalyticsEnabled>True</AnalyticsEnabled>
  <InstanceName>Prowlarr</InstanceName>
</Config>
EOF
    sudo chown "${PUID}:${PGID}" "${DOCKERPATH}/mediaserver/prowlarr/config.xml"
fi

if is_selected tdarr; then
    make_dir "${DOCKERPATH}/mediaserver/tdarr/server"
    make_dir "${DOCKERPATH}/mediaserver/tdarr/configs"
    make_dir "${DOCKERPATH}/mediaserver/tdarr/logs"
fi

if is_selected qbittorrentvpn && [[ ! -f "${DOCKERPATH}/mediaserver/qbittorrent/qBittorrent/qBittorrent.conf" ]]; then
    make_dir "${DOCKERPATH}/mediaserver/qbittorrent/qBittorrent"
    sudo tee "${DOCKERPATH}/mediaserver/qbittorrent/qBittorrent/qBittorrent.conf" > /dev/null <<EOF
[BitTorrent]
Session\DefaultSavePath=/downloads

[Preferences]
WebUI\AuthSubnetWhitelist=${QBIT_SUBNET}
WebUI\AuthSubnetWhitelistEnabled=true
EOF
    sudo chown -R "${PUID}:${PGID}" "${DOCKERPATH}/mediaserver/qbittorrent"
fi

# ─────────────────────────────────────────────
#  Backup plan + secrets folder (before Backrest starts)
# ─────────────────────────────────────────────
sudo mkdir -p /srv/kona-secrets && sudo chmod 700 /srv/kona-secrets
if is_selected backup; then
    make_dir "${DOCKERPATH}/cloudservices/backrest/data"
    make_dir "${DOCKERPATH}/cloudservices/backrest/config"
    make_dir "${DOCKERPATH}/cloudservices/backrest/cache"
    make_dir "${DOCKERPATH}/cloudservices/backrest/tmp"
    sudo mkdir -p /mnt/Backups
    backrest_default_config
fi

# ─────────────────────────────────────────────
#  Deploy selected services
# ─────────────────────────────────────────────
# GPU passthrough: if this machine has no /dev/dri, map a harmless placeholder
# instead so the containers still start (they just won't hardware-transcode).
if [[ -e /dev/dri ]]; then
    DRI_DEVICE=/dev/dri
else
    DRI_DEVICE=/dev/null
    if is_selected plex || is_selected tdarr || is_selected jellyfin; then
        warn "No /dev/dri found — Plex/Tdarr/Jellyfin will run without hardware transcoding."
    fi
fi
echo "DRI_DEVICE=${DRI_DEVICE}" >> "$SCRIPT_DIR/.env"

# Only add the portainer profile if the container doesn't already exist
ALL_ARGS=""
sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'portainer' || ALL_ARGS="--profile portainer"
[[ -n "${CF_TUNNEL_TOKEN:-}" ]] && ALL_ARGS="$ALL_ARGS --profile cloudflared"
for i in "${!SERVICES[@]}"; do
    [[ "${SELECTED[$i]}" == "1" ]] && ALL_ARGS="$ALL_ARGS --profile ${SVC_PROFILES[$i]}"
done

# --pull always = every run fetches the newest image of each selected app
# shellcheck disable=SC2086
sudo docker compose -f "$SCRIPT_DIR/docker-compose.yaml" $ALL_ARGS up -d --pull always

# ─────────────────────────────────────────────
#  Restored Portainer stacks / photo library (only after a restore)
# ─────────────────────────────────────────────
restore_extras

# ─────────────────────────────────────────────
#  Backrest hook scripts (optional stop/start + DB dump helpers)
# ─────────────────────────────────────────────
if is_selected backup; then
    make_dir "${DOCKERPATH}/backup"
    make_dir "${DOCKERPATH}/backup/dumps"
    sudo tee "${DOCKERPATH}/backup/backup.conf" > /dev/null <<CONF
DOCKERPATH="${DOCKERPATH}"
SEAFILE_DB_PASSWORD='${SEAFILE_DB_ROOT_PASSWORD:-}'
CONF
    sudo chmod 600 "${DOCKERPATH}/backup/backup.conf"
    for script in pre-cloudservices.sh post-cloudservices.sh pre-mediaserver.sh post-mediaserver.sh pre-infrastructure.sh post-infrastructure.sh; do
        sudo cp "${SCRIPT_DIR}/backup/${script}" "${DOCKERPATH}/backup/${script}"
        sudo chmod +x "${DOCKERPATH}/backup/${script}"
    done
fi
save_config

# ─────────────────────────────────────────────
#  Summary
# ─────────────────────────────────────────────
LOCAL_IP=$(hostname -I | awk '{print $1}')

print_url() {
    printf "│  %-22s ${CYAN}%-37s${RESET}│\n" "$1" "$2"
}

echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
printf "│                  ${GREEN}${BOLD}Installation Complete!${RESET}                      │\n"
echo "│                  Installed Services                          │"
echo "├──────────────────────────────────────────────────────────────┤"
print_url "Portainer" "http://${LOCAL_IP}:9000"
for i in "${!SERVICES[@]}"; do
    [[ "${SELECTED[$i]}" == "1" && "${SVC_PORTS[$i]}" != "-" ]] || continue
    print_url "${LABELS[$i]%%  *}" "http://${LOCAL_IP}:${SVC_PORTS[$i]}${SVC_PATHS[$i]}"
done
is_selected backup && print_url "Backup hooks" "${DOCKERPATH}/backup/"
if is_selected nzbget; then
    printf "│  ${DIM}%-60s${RESET}│\n" "NZBGet login — user: nzbget  /  pass: tegbzn6789 (change it)"
fi
if is_selected qbittorrentvpn; then
    if [[ "${GLUETUN_VPN_TYPE}" == "wireguard" ]]; then
        printf "│  ${DIM}%-60s${RESET}│\n" "VPN config: ${DOCKERPATH}/mediaserver/gluetun/wireguard/wg0.conf"
    else
        printf "│  ${DIM}%-60s${RESET}│\n" "VPN config: ${DOCKERPATH}/mediaserver/gluetun/custom.conf"
    fi
fi
is_selected vaultwarden && print_url "Vaultwarden URL" "${VAULTWARDEN_DOMAIN:-http://${LOCAL_IP}:8222}"
is_selected duckdns && print_url "DuckDNS" "(no UI — managing ${DOMAINNAME}.duckdns.org)"
[[ -n "${CF_TUNNEL_TOKEN:-}" ]] && print_url "Cloudflared" "(no UI — tunnel active)"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""

# Plain-text copy of the URLs (included in the backup)
SUMMARY_FILE="${DOCKERPATH}/install-summary.txt"
{
    echo "Service URLs — ${LOCAL_IP} — updated $(date)"
    echo "────────────────────────────────────────────"
    printf "  %-22s %s\n" "Portainer" "http://${LOCAL_IP}:9000"
    for i in "${!SERVICES[@]}"; do
        [[ "${SVC_PORTS[$i]}" == "-" ]] && continue
        printf "  %-22s %s\n" "${LABELS[$i]%%  *}" "http://${LOCAL_IP}:${SVC_PORTS[$i]}${SVC_PATHS[$i]}"
    done
} | sudo tee "$SUMMARY_FILE" > /dev/null
echo "Service URLs saved to ${SUMMARY_FILE}"
echo "To add more programs later, run:  sudo homelab-install   (or: sudo ${SCRIPT_DIR}/install.sh --apps plex,sonarr)"
echo ""
