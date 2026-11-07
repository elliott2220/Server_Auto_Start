#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  Bootstrap — the one command to run on a fresh, headless AlmaLinux box:
#
#    curl -fsSL https://raw.githubusercontent.com/elliott2220/Server_Auto_Start/main/bootstrap.sh | sudo bash
#
#  It installs git, downloads this repo to /opt/homelab-installer, and starts
#  the installer. Re-run it any time to update the installer and add programs.
#
#  Environment overrides:
#    HOMELAB_REPO    git URL to fetch   (default: elliott2220/Server_Auto_Start)
#    HOMELAB_BRANCH  branch             (default: main)
#    HOMELAB_DIR     install location   (default: /opt/homelab-installer)
# ─────────────────────────────────────────────────────────────────────────────
set -eu

REPO="${HOMELAB_REPO:-https://github.com/elliott2220/Server_Auto_Start.git}"
BRANCH="${HOMELAB_BRANCH:-main}"
DIR="${HOMELAB_DIR:-/opt/homelab-installer}"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root:  curl -fsSL <url>/bootstrap.sh | sudo bash" >&2
    exit 1
fi
if [[ "$REPO" == *CHANGE-ME* ]]; then
    echo "This copy of bootstrap.sh has no repo URL yet. Run with:" >&2
    echo "  HOMELAB_REPO=https://github.com/elliott2220/Server_Auto_Start.git bash bootstrap.sh" >&2
    exit 1
fi
if ! grep -qiE 'rhel|centos|almalinux|rocky|fedora' /etc/os-release; then
    echo "This installer targets AlmaLinux / RHEL-family systems." >&2
    exit 1
fi

echo "==> Installing git and curl"
dnf -y install git curl newt >/dev/null

if [[ -d "$DIR/.git" ]]; then
    echo "==> Updating $DIR"
    git -C "$DIR" fetch --quiet origin "$BRANCH"
    git -C "$DIR" reset --quiet --hard "origin/$BRANCH"
else
    echo "==> Downloading installer to $DIR"
    git clone --quiet --depth 1 --branch "$BRANCH" "$REPO" "$DIR"
fi

ln -sf "$DIR/install.sh" /usr/local/bin/homelab-install
echo "==> Starting installer (re-run later with: sudo homelab-install)"
# When piped from curl, stdin is the script itself; reattach the terminal.
if [[ -r /dev/tty ]]; then
    exec "$DIR/install.sh" "$@" </dev/tty
else
    exec "$DIR/install.sh" "$@"
fi
