# Caddy

This directory is the Git source of truth for the Caddy configuration used by the homelab reverse proxy.

The active server config should be exposed to Caddy through `/etc/caddy/Caddyfile`, but the file itself should live in this repository.

## Server Layout

Recommended server clone path:

```bash
/opt/homelab/infra-config
```

Recommended service user:

```bash
homelab
```

Example initial checkout:

```bash
sudo mkdir -p /opt/homelab
sudo chown homelab:homelab /opt/homelab
sudo -u homelab git clone http://192.168.50.42:3000/homelab/infra-config.git /opt/homelab/infra-config
```

## Link Caddyfile

Move the local Caddyfile out of the way and replace it with a symlink to the repository-managed file:

```bash
sudo mv /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak
sudo ln -s /opt/homelab/infra-config/caddy/Caddyfile /etc/caddy/Caddyfile
```

## Validate And Reload

Run these commands after every config change:

```bash
caddy fmt --overwrite /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

For local repository validation before deploying:

```bash
caddy fmt --overwrite caddy/Caddyfile
caddy validate --config caddy/Caddyfile
```

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
caddy fmt --overwrite caddy/Caddyfile
caddy validate --config caddy/Caddyfile
sudo systemctl reload caddy
```

The example Navidrome route is HTTP-only:

```caddy
http://navidrome.infra.shshx.net {
	reverse_proxy 192.168.50.42:4533
}
```

Add the matching DNS override in Unbound:

```text
navidrome.infra.shshx.net -> 192.168.50.40
```

TLS for `*.infra.shshx.net` should be added later through Cloudflare DNS Challenge after HTTP routing is confirmed.
