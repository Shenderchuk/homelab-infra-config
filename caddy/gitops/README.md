# Caddy GitOps

This is a lightweight pull-based GitOps loop for the Caddy host.

The systemd timer runs every minute. The sync script fetches `origin/main`, validates the fetched candidate Caddy config in a temporary checkout, and only then fast-forwards `/opt/infra-config` and reloads Caddy.

## Install On Caddy Host

Run on `root@caddy` after the repo has this directory:

```bash
cd /opt/infra-config
git pull
chmod +x caddy/gitops/caddy-gitops-sync.sh
cp caddy/gitops/caddy-gitops.service /etc/systemd/system/caddy-gitops.service
cp caddy/gitops/caddy-gitops.timer /etc/systemd/system/caddy-gitops.timer
systemctl daemon-reload
systemctl enable --now caddy-gitops.timer
```

## Verify

```bash
systemctl list-timers caddy-gitops.timer
systemctl start caddy-gitops.service
journalctl -u caddy-gitops.service -n 50 --no-pager
```

## Operational Notes

- The checkout must be clean. Local edits in `/opt/infra-config` intentionally block deployment.
- The `root` user on `caddy` must be able to fetch the Git remote.
- Invalid Caddy commits are not deployed; the active Caddy process keeps running the previous config.
- The script uses `git merge --ff-only`, so force-pushed history or diverged local state will fail instead of rewriting the checkout.