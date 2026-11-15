# OpenWrt monitoring preparation

Telegraf configuration targets gw02-i7505 and reads InfluxDB settings from environment variables. This is a starting configuration, not an installed or validated deployment.

The existing Loki Alloy receiver on 192.168.50.47 UDP 1515 labels data as MikroTik. Add a separate RFC3164 listener with OpenWrt labels before configuring OpenWrt remote syslog; do not reuse the MikroTik listener.

Grafana and InfluxDB health endpoints were reachable on inspection. The provided Influx token could query the existing bucket; write permissions and a suitable OpenWrt bucket remain to be verified. Grafana API returned 401 for the supplied token. Rotate or replace that token before dashboard provisioning.
