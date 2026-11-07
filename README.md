# Homelab Installer

Rebuild a home server on a blank **AlmaLinux** machine with one command: pick the apps you want, optionally restore your last backup, done.

> Forked, with the original author's permission, from [btaylor188/privatecloud](https://github.com/btaylor188/privatecloud) (menu + docker-compose profiles), then extended with system prep, backup/restore, a catalog-driven menu, and more apps.

## One-command install (fresh headless Alma box)

```bash
curl -fsSL https://raw.githubusercontent.com/elliott2220/Server_Auto_Start/main/bootstrap.sh | sudo bash
```

That installs `git`, downloads this repo to `/opt/homelab-installer`, and starts the installer. Run `sudo homelab-install` any time afterwards to **add more apps** or update the installer.

Run it as root (the command above uses sudo). Prefer to read it first? `git clone https://github.com/elliott2220/Server_Auto_Start.git` and run `sudo ./install.sh`.

## What it does, in order

1. **Menu** — tick the apps you want (`apps.txt` drives it). `--apps plex,sonarr,radarr` pre-ticks some; `--list` shows everything.
2. **Restore prompt** — point it at a restic backup (NFS share, local folder/USB, or a `b2:`/`sftp:`/`s3:` URL) and give the repository password.
3. **System prep** — latest `restic` + `rclone` from upstream, NFS mounts for your NAS, Docker from Docker's official repo, and optional tuning (log caps, swappiness, automatic security updates, weekly image prune, key-only SSH).
4. **Restore** — shows a dry-run preview, asks to confirm, restores configs *before* any app is configured so your Plex/Sonarr/Radarr/Tdarr settings win.
5. **Deploy** — `docker compose up -d --pull always`: every run fetches the newest image of each selected app.
6. **Extras after a restore** — offers to start your saved Portainer stacks (your own apps) and to pull Immich photos back from Backblaze.

## Replacing hardware (disaster recovery)

1. Install AlmaLinux (minimal, headless) and note the machine's IP.
2. On your NAS, allow the new machine's IP on the NFS shares.
3. Run the one-liner above. Tick the same apps as before.
4. Say **yes** to restore. Choose *Folder on this machine* and give `/mnt/Backups/Docker/<oldhostname>` (the NAS is mounted for you in step 3), or choose *NFS share*.
5. Enter the repository password (**from your password manager — see below**).
6. When it finishes: open Plex, Sonarr, Radarr, Tdarr. Everything should be as you left it.

### Things the backup does NOT contain

| Item | Where it really lives | What to do |
|---|---|---|
| **Restic repository password** | Only inside Backrest's `config.json` | **Store it in your password manager.** Without it the backup cannot be opened. The installer shows it once on a new setup and makes you confirm you saved it. |
| Media files | The NAS | Re-mounted via NFS; not copied. |
| Immich photos | Backblaze B2 (`rclone` job) | The restore step offers to download them. Then in Immich choose *Restore from backup* and pick the newest database dump. |
| Immich thumbnails / transcodes | Regenerated | Immich rebuilds them. |
| Data of apps you built yourself | Docker volumes (not in the file backup) | Back them up separately (e.g. to B2) and restore through the app. |
| Cloudflare / B2 / Plex-claim tokens | Prompted when needed (or inside the restored `/srv/kona-secrets`) | Never stored in this repo. |

## Adding a program later

Two edits, no changes to install logic:

1. Add one line to `apps.txt`:
   ```
   name|Group|Label   description|web-port|url-path|compose-profile|dirs,to,create
   ```
2. Add its service to `docker-compose.yaml` with `profiles: [name]`.

Run `sudo homelab-install`, tick it, done. If it needs a password or secret, add a small prompt block in `install.sh` (see Paperless for a generated-secret example).

## Apps

| Group | Apps |
|---|---|
| Infrastructure | WUD, Netdata, DuckDNS, Uptime Kuma, Speedtest, **Backrest**, **Dozzle**, **Homepage** |
| Downloaders | NZBGet, qBittorrent+VPN |
| \*ARR! | Prowlarr, Sonarr, Radarr, **Lidarr**, **Bazarr**, Tdarr (Intel Quick Sync) |
| Media | Plex, **Jellyfin**, Seerr, **Tautulli**, **Navidrome** |
| Books | Audiobookshelf, Grimmory, Shelfmark |
| Private cloud | Immich, Seafile, Vaultwarden, **Paperless-ngx** |

Bold = added in this fork (plus FlareSolverr, Maintainerr, Stirling-PDF, Syncthing, ntfy). Portainer is always installed; Cloudflared only if you give it a tunnel token.

### Good candidates to add next
Unpackerr and Recyclarr (need Sonarr/Radarr API keys — a prompt block), Scrutiny (disk SMART), Gotify/ntfy (notifications), Tailscale (remote access), Home Assistant (host networking), Pi-hole (if you want DNS on this box), Calibre-Web.

## What the system prep does and why

- **NFS mount points are made immutable (`chattr +i`) while unmounted** and Docker is ordered after the mounts. Without this, a container that starts before the NAS is up writes to the empty local folder; on the original server this showed up as four missed weekly backups ("repository does not exist").
- **Backrest default plan** covers all of `/opt/docker` (so the repo password and Portainer stacks are included) and `/srv/kona-secrets`, skips Plex cache/logs, and pings healthchecks.io if you give a URL. The plan's `CONDITION_ANY_ERROR` hook also fires for failures that happen *before* a snapshot starts — verify in the Backrest UI that the hook saved correctly.
- Container logs are capped (3 × 10 MB), because Docker's default is unbounded.

## Honest limits

**Use at your own risk.** This is a personal project. Read the scripts before running them as root, and test the restore path on a spare machine first.

- Written against AlmaLinux 10 and validated by static checks (`bash -n`, `docker compose config` with every profile enabled, no duplicate container names or port clashes). It has **not** been run end-to-end on a blank machine — do a test run on a spare box or VM before you depend on it, especially the restore path.
- Restic restores file contents and permissions; databases that were copied while running (Plex, Sonarr/Radarr SQLite) are restored as-is. Sonarr/Radarr also keep their own zip backups inside their config folders.
- `dnf-automatic` configuration paths differ between DNF versions; the installer tries both and warns if neither works.

## Files

```
bootstrap.sh          curl entry point: installs git, fetches repo, runs install.sh
install.sh            menu + prompts + orchestration
apps.txt              the app catalog (menu, deploy, URL summary all read this)
docker-compose.yaml   every service, gated by profiles
docker.sh             Docker CE install (skipped if present)
lib/prep.sh           restic/rclone, NFS, tuning
lib/restore.sh        restic restore, Portainer stacks, Immich photos
lib/backrest.sh       default Backrest repo + plan
backup/               optional Backrest stop/start hook scripts (from upstream)
```

Secrets are never committed (`.env` is git-ignored and deleted on exit).
