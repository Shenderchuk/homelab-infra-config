# OPNsense Telegraf GitOps

This directory is the Git source of truth for OPNsense Telegraf exec
configuration on `gw01-i7505`.

The active OPNsense paths are:

```sh
/usr/local/etc/telegraf.conf
/usr/local/etc/telegraf.d/
/usr/local/bin/opnsense-temperature.sh
/usr/local/bin/igc_stats.sh
/etc/rc.conf.d/telegraf
```

`/usr/local/etc/telegraf.conf` contains the InfluxDB token and is not committed.
Use `telegraf.conf.example` as a restore template and replace the redacted
values on the host.

## Managed Files

- `telegraf.d/cpu-temperature.conf` runs `opnsense-temperature.sh`.
- `telegraf.d/igc_stats.conf` runs `igc_stats.sh`.
- `bin/opnsense-temperature.sh` emits ACPI, CPU if available, and NVMe SSD
  temperatures as `opnsense_temperature`.
- `bin/igc_stats.sh` is imported from the current host and intentionally left
  behaviorally unchanged.

## Bootstrap On OPNsense

Run as `root` on `gw01-i7505`:

```sh
pkg install -y git-lite
mkdir -p /opt
git clone ssh://git@192.168.50.42:2222/homelab/infra-config.git /opt/infra-config
chmod 0755 /opt/infra-config/monitoring/opnsense/gitops/opnsense-telegraf-gitops-sync.sh
mkdir -p /usr/local/etc/cron.d
install -o root -g wheel -m 0644 \
  /opt/infra-config/monitoring/opnsense/gitops/opnsense-telegraf-gitops.cron \
  /usr/local/etc/cron.d/opnsense-telegraf-gitops
service cron restart
```

The cron job runs every minute. It fetches `origin/main`, validates the fetched
candidate Telegraf exec configuration from a temporary checkout, fast-forwards
`/opt/infra-config`, installs the managed files, validates the active Telegraf
configuration, then restarts Telegraf.

## Restore Telegraf

1. Install Telegraf from the OPNsense plugin/package UI.
2. Recreate `/usr/local/etc/telegraf.conf` from `telegraf.conf.example` and
   insert the real InfluxDB token and organization.
3. Install the rc config:

```sh
install -o root -g wheel -m 0644 \
  /opt/infra-config/monitoring/opnsense/rc.conf.d/telegraf \
  /etc/rc.conf.d/telegraf
```

4. Run the GitOps sync once:

```sh
/opt/infra-config/monitoring/opnsense/gitops/opnsense-telegraf-gitops-sync.sh
```

5. Validate service and metrics:

```sh
telegraf config check --config /usr/local/etc/telegraf.conf --config-directory /usr/local/etc/telegraf.d
service telegraf restart
service telegraf onestatus
/usr/local/bin/opnsense-temperature.sh
```

Expected temperature output includes `type=acpi_zone`, `type=nvme_composite`,
and `type=nvme_sensor`. `type=cpu_core` is optional because the current host
does not expose `dev.cpu.*.temperature`.

## Grafana And Influx Checks

From this repository on an admin workstation:

```powershell
.\scripts\Test-InfluxEnv.ps1
.\scripts\Test-GrafanaEnv.ps1 -DashboardUid deftsw6fen6i2of
.\scripts\Test-GrafanaEnv.ps1 -DashboardUid network-connectivity-fault-isolation
```

The current local Grafana service account token must be valid; a `401` from
authenticated Grafana endpoints means `.secrets/grafana.env` needs rotation.
