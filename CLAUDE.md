# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is
A menu-driven installer that rebuilds a home server on a blank AlmaLinux machine: system prep (restic, rclone, NFS, tuning) → optional restic restore → Docker Compose deploy of the apps you tick. Forked from btaylor188/privatecloud.

## Layout
- `bootstrap.sh` — curl entry point; installs git, clones to /opt/homelab-installer, runs install.sh
- `install.sh` — flags, menu, prompts, orchestration. `set -eu`; must stay idempotent (it is re-run to add apps)
- `apps.txt` — THE app catalog: drives the menu, profile selection, data-dir creation and URL summary
- `docker-compose.yaml` — every service, gated by `profiles: [<name>]`; two networks `internal`/`external` are created by install.sh
- `lib/prep.sh` (restic/rclone/NFS/tuning), `lib/restore.sh` (restic restore + extras), `lib/backrest.sh` (default Backrest repo+plan)
- `backup/` — optional upstream Backrest stop/start hooks (not wired by default)

## Adding an app
1. One line in `apps.txt` (name|group|label|port|urlpath|profile|dirs)
2. Service(s) in `docker-compose.yaml` with `profiles: [profile]`
3. Only if it needs a secret/prompt: a block in install.sh near the other `is_selected` blocks, plus the variable in the `.env` heredoc and `save_config`

## Rules
- Never commit secrets (tokens, B2 keys, healthchecks URLs, passwords). Prompt for them or generate them.
- Generated database passwords go through `save_config` — they are copied to `$DOCKERPATH/homelab.conf` so a restore reuses them.
- GPU devices use `${DRI_DEVICE:-/dev/dri}` so machines without an iGPU still start containers.
- Validate changes without a test machine: `bash -n` on every script, and `docker compose -f docker-compose.yaml <all --profile flags> config -q` with a dummy `.env`.
- Order in install.sh matters: restore must run before the pre-config blocks (they only write config files that don't already exist).
