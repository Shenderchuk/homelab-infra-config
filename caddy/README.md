# Caddy

This directory is the Git source of truth for the Caddy configuration used by the homelab reverse proxy.

The active server config should be exposed to Caddy through `/etc/caddy/Caddyfile`, but the file itself should live in this repository.

## Server Layout

Active server clone path:

```bash
/opt/infra-config
```

Active Caddyfile symlink:

```bash
/etc/caddy/Caddyfile -> /opt/infra-config/caddy/Caddyfile
```

Example initial checkout:

```bash
git clone ssh://git@portainer:2222/homelab/infra-config.git /opt/infra-config
```

## Link Caddyfile

Move the local Caddyfile out of the way and replace it with a symlink to the repository-managed file:

```bash
sudo mv /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak
sudo ln -s /opt/infra-config/caddy/Caddyfile /etc/caddy/Caddyfile
```

## Validate And Reload

Run these commands after every manual config change:

```bash
caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

For local repository validation before deploying:

```bash
caddy validate --config caddy/Caddyfile
```

## GitOps Pull Sync

A lightweight pull-based GitOps setup lives in `caddy/gitops/`.

Install it on `root@caddy`:

```bash
cd /opt/infra-config
git pull
chmod +x caddy/gitops/caddy-gitops-sync.sh
cp caddy/gitops/caddy-gitops.service /etc/systemd/system/caddy-gitops.service
cp caddy/gitops/caddy-gitops.timer /etc/systemd/system/caddy-gitops.timer
systemctl daemon-reload
systemctl enable --now caddy-gitops.timer
```

The timer fetches `origin/main`, validates the fetched candidate Caddy config, fast-forwards `/opt/infra-config`, and reloads Caddy only after validation succeeds.

## Smoke Test

The initial active site is a plain HTTP test endpoint:

```caddy
:80 {
	respond "Hello Homelab!"
}
```

After reload, verify it from the LAN:

```bash
curl http://192.168.50.40
```

Expected response:

```text
Hello Homelab!
```

## Add A Site

Site definitions live in `sites/`.

To activate a new service:

```bash
cp caddy/sites/navidrome.caddy.example caddy/sites/navidrome.caddy
caddy validate --config caddy/Caddyfile
sudo systemctl reload caddy
```

The example Navidrome route is HTTP-only:

```caddy
http://navidrome.infra.shshx.net {
	redir / /app/
	reverse_proxy portainer.infra.shshx.net:4533
}
```

Add the matching DNS override in Unbound:

```text
navidrome.infra.shshx.net -> 192.168.50.40
```

TLS for `*.infra.shshx.net` should be added later through Cloudflare DNS Challenge after HTTP routing is confirmed.