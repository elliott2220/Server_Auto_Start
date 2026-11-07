#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  System preparation for a fresh AlmaLinux box.
#  Sourced by install.sh (uses its ask/yesno helpers). Everything here is
#  idempotent: re-running the installer will not duplicate work.
# ─────────────────────────────────────────────────────────────────────────────

warn() { echo "  ${YELLOW}!${RESET} $*"; }
info() { echo "  ${GREEN}✓${RESET} $*"; }

# yesno "question" default(y|n)  → returns 0 for yes
yesno() {
    local q="$1" def="${2:-n}" a hint="y/N"
    [[ "$def" == "y" ]] && hint="Y/n"
    read -r -p "  $q [$hint]: " a
    a="${a:-$def}"
    [[ "$a" =~ ^[Yy] ]]
}

_arch() {
    case "$(uname -m)" in
        x86_64)  echo amd64 ;;
        aarch64) echo arm64 ;;
        *) echo "unsupported architecture: $(uname -m)" >&2; return 1 ;;
    esac
}

# ── Latest restic / rclone straight from upstream ───────────────────────────
install_restic() {
    local arch tag ver tmp
    arch=$(_arch)
    tag=$(curl -fsSL https://api.github.com/repos/restic/restic/releases/latest \
          | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/') || true
    if [[ -z "$tag" ]]; then
        warn "Could not look up the latest restic release; trying the distro package."
        sudo dnf -y install epel-release >/dev/null 2>&1 || true
        sudo dnf -y install restic && return 0
        return 1
    fi
    if command -v restic >/dev/null 2>&1 && restic version 2>/dev/null | grep -q " ${tag} "; then
        info "restic ${tag} already installed"; return 0
    fi
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/restic.bz2" \
        "https://github.com/restic/restic/releases/download/v${tag}/restic_${tag}_linux_${arch}.bz2"
    bunzip2 "$tmp/restic.bz2"
    sudo install -m 0755 "$tmp/restic" /usr/local/bin/restic
    rm -rf "$tmp"
    info "restic ${tag} installed"
}

install_rclone() {
    local arch tmp
    arch=$(_arch)
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/rclone.zip" "https://downloads.rclone.org/rclone-current-linux-${arch}.zip"
    unzip -q -o "$tmp/rclone.zip" -d "$tmp"
    sudo install -m 0755 "$tmp"/rclone-*-linux-"${arch}"/rclone /usr/local/bin/rclone
    rm -rf "$tmp"
    info "rclone $(rclone version | head -1 | awk '{print $2}') installed"
}

# ── NFS shares ──────────────────────────────────────────────────────────────
# Fixes a real failure mode: if Docker starts before the NAS is mounted, a
# container bind-mounts the EMPTY local folder, and backups/imports then land on
# the local disk (or fail with "repository does not exist"). We guard it twice:
#   1. mount points are made immutable (chattr +i) while unmounted, so nothing
#      can be written to them unless the NFS share is really mounted on top
#   2. docker.service is ordered after the NFS mounts
setup_nfs() {
    echo ""
    echo "  ${BOLD}NAS / NFS shares${RESET}  (leave the address blank to skip)"
    ask "NAS IP or hostname" NAS_HOST "${NAS_HOST:-}"
    [[ -z "${NAS_HOST:-}" ]] && { warn "Skipping NFS setup."; return 0; }

    ask "Shares as  export=mountpoint  (space separated)" NFS_MAPS \
        "${NFS_MAPS:-/volume1/Movies=/mnt/Media/Movies /volume1/TV=/mnt/Media/TV /volume1/Backups=/mnt/Backups}"
    # NFSv3 matches how the original server runs; set NFS_OPTS to override.
    local opts="${NFS_OPTS:-nfsvers=3,hard,_netdev,nofail,x-systemd.mount-timeout=30}"

    sudo dnf -y install nfs-utils >/dev/null
    sudo setsebool -P virt_use_nfs 1 2>/dev/null || warn "setsebool virt_use_nfs failed (SELinux off?)"

    local map exp mp unit units=()
    for map in $NFS_MAPS; do
        exp="${map%%=*}"; mp="${map#*=}"
        sudo mkdir -p "$mp"
        if ! mountpoint -q "$mp"; then
            sudo chattr +i "$mp" 2>/dev/null || warn "could not protect $mp with chattr +i"
        fi
        if ! grep -qE "^[^#]*[[:space:]]${mp}[[:space:]]" /etc/fstab; then
            echo "${NAS_HOST}:${exp}  ${mp}  nfs  ${opts}  0 0  # homelab-installer" | sudo tee -a /etc/fstab >/dev/null
        fi
        unit=$(systemd-escape -p --suffix=mount "$mp")
        units+=("$unit")
    done
    sudo systemctl daemon-reload
    for map in $NFS_MAPS; do
        mp="${map#*=}"
        if sudo mount "$mp" 2>/dev/null || mountpoint -q "$mp"; then
            info "mounted $mp"
        else
            warn "could not mount $mp — check the NAS export permissions for this host's IP"
        fi
    done

    # Docker waits for (but does not hard-depend on) the NFS mounts.
    sudo mkdir -p /etc/systemd/system/docker.service.d
    sudo tee /etc/systemd/system/docker.service.d/10-homelab-mounts.conf >/dev/null <<EOF
[Unit]
After=network-online.target remote-fs.target ${units[*]}
Wants=network-online.target ${units[*]}
EOF
    sudo systemctl daemon-reload
    info "Docker is ordered after the NFS mounts"
}

# ── Optional tuning ─────────────────────────────────────────────────────────
tune_system() {
    echo ""
    echo "  ${BOLD}System tuning${RESET}"

    if yesno "Cap container log size (stops logs filling the disk)?" y; then
        if [[ -f /etc/docker/daemon.json ]]; then
            warn "/etc/docker/daemon.json exists — leaving it alone."
        else
            sudo mkdir -p /etc/docker
            sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
            info "container logs capped at 3 x 10 MB"
        fi
    fi

    if yesno "Lower swappiness to 10 (prefer RAM over swap)?" y; then
        echo "vm.swappiness = 10" | sudo tee /etc/sysctl.d/99-homelab.conf >/dev/null
        sudo sysctl -q --system || true
        info "vm.swappiness = 10"
    fi

    if yesno "Install security updates automatically (never reboots by itself)?" y; then
        if sudo dnf -y install dnf-automatic >/dev/null 2>&1; then
            local cfg
            for cfg in /etc/dnf/automatic.conf /etc/dnf/dnf5-plugins/automatic.conf; do
                [[ -f "$cfg" ]] || continue
                sudo sed -i -E 's/^(upgrade_type *=).*/\1 security/; s/^(apply_updates *=).*/\1 yes/' "$cfg"
            done
            sudo systemctl enable --now dnf-automatic.timer >/dev/null 2>&1 \
                || sudo systemctl enable --now dnf5-automatic.timer >/dev/null 2>&1 \
                || warn "could not enable the dnf-automatic timer"
            info "automatic security updates on"
        else
            warn "dnf-automatic not available"
        fi
    fi

    if yesno "Prune unused Docker images weekly (reclaims disk)?" y; then
        sudo tee /etc/systemd/system/docker-prune.service >/dev/null <<'EOF'
[Unit]
Description=Prune unused Docker images and build cache
[Service]
Type=oneshot
ExecStart=/usr/bin/docker image prune -af --filter until=168h
ExecStart=/usr/bin/docker builder prune -af --filter until=168h
EOF
        sudo tee /etc/systemd/system/docker-prune.timer >/dev/null <<'EOF'
[Unit]
Description=Weekly Docker prune
[Timer]
OnCalendar=weekly
Persistent=true
[Install]
WantedBy=timers.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable --now docker-prune.timer >/dev/null 2>&1
        info "weekly Docker prune enabled"
    fi

    # Off by default: locking yourself out of a headless box is the worst outcome.
    if [[ -s /root/.ssh/authorized_keys ]] && \
       yesno "Disable SSH password login (key-only)? Only say yes if your key already works" n; then
        sudo tee /etc/ssh/sshd_config.d/00-homelab-hardening.conf >/dev/null <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
EOF
        sudo systemctl reload sshd && info "SSH is now key-only"
    fi
}

prep_system() {
    echo ""
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│                      System preparation                      │"
    echo "└──────────────────────────────────────────────────────────────┘"
    [[ -f /etc/os-release ]] && grep -qiE 'almalinux|rhel|rocky|centos' /etc/os-release \
        || warn "Not an AlmaLinux/RHEL-family system — some steps may fail."
    sudo dnf -y install curl tar bzip2 unzip git python3 >/dev/null
    install_restic
    install_rclone
    setup_nfs
    tune_system
}
