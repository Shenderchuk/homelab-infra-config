# Homelab Backup

GitOps-managed local backup staging for Docker service configuration data.

## Architecture

```text
/mnt/configs/<service>
        -> Python homelab-backup
        -> rsync
        -> /mnt/backup/services/app-<service>/data
        -> Backrest / Restic
        -> Backblaze B2
```

The Python CLI validates declarative YAML service configs, checks the NAS mount, safely
coordinates Docker container state, runs system `rsync`, writes JSON Lines logs, and writes
machine-readable status metadata. Backrest/Restic setup is intentionally out of scope here.

## Components

- Python CLI: `homelab-backup`.
- YAML configs: `/etc/homelab-backup/defaults.yaml` and `/etc/homelab-backup/services/*.yaml`.
- Virtual environment: `/opt/homelab-backup/.venv`.
- systemd service: `homelab-service-backup@.service`.
- systemd timer: `homelab-service-backup@.timer` plus generated drop-ins.
- Deployment utility: `homelab-backup-deploy` or `backup/deploy/*.py`.
- Logs: journald plus optional `/var/log/homelab-backup/*.log`.
- Status: `/var/lib/homelab-backup/status/*.json`.
- NAS staging: `/mnt/backup/services/<service>/data`.
- Restic snapshots: created later by Backrest, not by this app.

## Manual Python Setup

Package names depend on the OS. On Debian or Ubuntu:

```bash
apt-get update
apt-get install -y python3 python3-venv python3-pip rsync
```

Create the virtual environment:

```bash
mkdir -p /opt/homelab-backup
python3 -m venv /opt/homelab-backup/.venv
```

Install packaging tools and the app:

```bash
/opt/homelab-backup/.venv/bin/python -m pip install --upgrade \
  pip setuptools wheel

/opt/homelab-backup/.venv/bin/pip install \
  -r /opt/homelab-infra-config/backup/requirements.txt

/opt/homelab-backup/.venv/bin/pip install \
  /opt/homelab-infra-config/backup
```

## CLI

```bash
/opt/homelab-backup/.venv/bin/homelab-backup --help
/opt/homelab-backup/.venv/bin/homelab-backup list
/opt/homelab-backup/.venv/bin/homelab-backup validate app-navidrome
/opt/homelab-backup/.venv/bin/homelab-backup inspect app-navidrome
/opt/homelab-backup/.venv/bin/homelab-backup run --dry-run app-navidrome
/opt/homelab-backup/.venv/bin/homelab-backup run app-navidrome
/opt/homelab-backup/.venv/bin/homelab-backup status app-navidrome
```

## systemd

Run manually:

```bash
systemctl start homelab-service-backup@app-navidrome.service
systemctl status homelab-service-backup@app-navidrome.service
```

Enable the timer after a successful dry-run and controlled backup:

```bash
systemctl enable --now homelab-service-backup@app-navidrome.timer
systemctl status homelab-service-backup@app-navidrome.timer
systemctl list-timers 'homelab-service-backup@*'
```

The deployment utility generates:

```text
/etc/systemd/system/homelab-service-backup@app-navidrome.timer.d/schedule.conf
```

from the YAML schedule.

## GitOps Deployment

The production checkout is:

```text
/opt/homelab-infra-config
```

The repository is:

```text
ssh://git@192.168.50.42:2222/homelab/infra-config.git
```

The deploy key is:

```text
/root/.ssh/portainer
```

Host key verification is required. The deployment utility uses `ssh-keyscan` to populate
`/root/.ssh/known_hosts`; it never uses `StrictHostKeyChecking=no`.

Dry-run:

```bash
python3 backup/deploy/install.py --dry-run
```

Install or update:

```bash
python3 backup/deploy/install.py
python3 backup/deploy/update.py
```

The normal install does not enable service backup timers. Enable them only after validation:

```bash
homelab-backup-deploy update --enable-service-timers
```

## Logs

```bash
journalctl -u homelab-service-backup@app-navidrome.service
journalctl -u homelab-service-backup@app-navidrome.service -f
tail -f /var/log/homelab-backup/app-navidrome.log
```

Example JSON event:

```json
{"component":"homelab-backup","event":"backup_completed","level":"INFO","service":"app-navidrome"}
```

Do not log environment variables, `.env` contents, passwords, SSH keys, access tokens, or raw
command output that may contain secrets.

## Loki Integration

Example Alloy journald scrape:

```hcl
loki.source.journal "homelab_backup" {
  matches = "_SYSTEMD_UNIT=homelab-service-backup@app-navidrome.service"
  labels = {
    job = "homelab-backup",
  }
  forward_to = [loki.write.default.receiver]
}
```

Example LogQL:

```logql
{job="homelab-backup"} | json
{job="homelab-backup"} | json | service="app-navidrome"
{job="homelab-backup"} | json | level="ERROR"
{job="homelab-backup"} | json | event="backup_failed"
```

Do not change production Alloy configuration automatically from this backup deployment.

## Add A New Service

1. Find the Compose file.
2. Identify source bind mounts that contain service state.
3. Choose `none` or `stop-container`.
4. Create `/etc/homelab-backup/services/<service>.yaml`.
5. Run `homelab-backup validate <service>`.
6. Run `homelab-backup inspect <service>`.
7. Run `homelab-backup run --dry-run <service>`.
8. Deploy the config.
9. Enable the timer after a controlled backup.
10. Run one backup manually.
11. Check destination contents.
12. Check container state.
13. Check logs and status JSON.
14. Later create the Backrest plan.

## Restic Behavior

Every Backrest/Restic run creates a snapshot. Unchanged blocks are not uploaded again, changes
are deduplicated at chunk level, and a new snapshot is not a full new copy. Snapshot metadata is
small. This app may update NAS staging through `rsync --delete`; long-term history and retention
belong to Restic/Backrest.

## Restore Navidrome

Manual restore from NAS staging:

```text
1. Stop the Navidrome container.
2. Validate /mnt/backup/services/app-navidrome/data.
3. Copy data back to /mnt/configs/navidrome.
4. Restore ownership and permissions.
5. Start the container.
6. Validate running state and health.
```

No automatic restore is implemented in this task.

## Troubleshooting

- Python missing: install `python3`, `python3-venv`, and `python3-pip`.
- Broken venv: remove and recreate `/opt/homelab-backup/.venv`, then reinstall.
- Dependency install failed: check DNS, package manager, pip, and Gitea checkout.
- Config validation failed: run `homelab-backup validate <service>` and fix the YAML error.
- NAS mount missing: check `findmnt -T /mnt/backup/services`.
- Destination read-only: check mount options and NAS permissions.
- Container not found: verify Compose project/service labels with `docker inspect`.
- Container ambiguous: add a safer selector or explicit `container_name` override in YAML.
- `rsync` exit code 23: inspect filesystem permissions and transient file changes.
- Container failed to restart: check Docker logs and the critical `container_restore_failed` event.
- Healthcheck timeout: inspect `docker inspect` health logs; Navidrome may be running but unhealthy.
- Timer did not run: check `systemctl list-timers 'homelab-service-backup@*'`.
- Git pull failed: check checkout cleanliness and deploy key access.
- SSH host key changed: verify the Gitea host fingerprint before updating `known_hosts`.
