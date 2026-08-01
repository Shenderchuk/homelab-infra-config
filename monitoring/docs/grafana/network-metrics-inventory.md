# Network Metrics Inventory

Generated from sanitized InfluxDB schema discovery for bucket `opnsense` over the last 24 hours. Secret values from `.secrets/influx.env` are not included.

## Summary

- InfluxDB `/health`: pass.
- Authenticated `/api/v2/buckets` and `/api/v2/query`: OK when checked through `scripts/Test-InfluxEnv.ps1`.
- Bucket used: `opnsense`.
- Host discovered: `gw01-i7505`.
- LAN ping target discovered from the actual `ping.url` tag: `192.168.50.4`.
- Local incident data maps `192.168.50.4` to `sw01-crs310`, so the dashboard treats it as the CRS310 LAN control target.
- Interfaces discovered from the actual `net.interface` tag: `igc0`, `igc1`.
- Driver-level Intel igc metrics discovered in `opnsense_igc` for `interface=igc1`.
- Gateway tag/measurement was not discovered.
- External multi-target ping was not discovered; Internet telemetry is available through `internet_speed` only.

## Measurements

| bucket | measurement | fields | tags | example tag values | frequency | purpose | Network problems it helps detect |
|---|---|---|---|---|---|---|---|
| opnsense | `ping` | `average_response_ms`, `maximum_response_ms`, `minimum_response_ms`, `packets_received`, `packets_transmitted`, `percent_packet_loss`, `result_code`, `standard_deviation_ms`, `ttl` | `host`, `url` | host: `gw01-i7505`; url: `192.168.50.4` | about 10s | ICMP control probe from OPNsense to CRS310 | LAN reachability loss, packet loss, latency spikes, jitter to the LAN switch |
| opnsense | `internet_speed` | `download`, `jitter`, `latency`, `location`, `packet_loss`, `upload` | `host`, `server_id`, `source`, `test_mode` | host: `gw01-i7505`; source: `brake.vodafone.ua:8080`; test_mode: `single` | about 6m from samples | Periodic Internet speed/quality test | Internet packet loss, WAN/ISP latency and jitter correlation, throughput degradation |
| opnsense | `net` | `bytes_recv`, `bytes_sent`, `drop_in`, `drop_out`, `err_in`, `err_out`, `packets_recv`, `packets_sent`, `speed` | `host`, `interface` | host: `gw01-i7505`; interface: `igc0`, `igc1` | about 10s | Interface counters for WAN/LAN ports | Traffic spikes, packet drops, interface errors, missing interface samples |
| opnsense | `opnsense_igc` | `link_irq`, `watchdog_timeouts`, `crc_errs`, `symbol_errors`, `recv_errs`, `missed_packets`, `rx_overruns`, `dropped` | `host`, `interface` | host: `gw01-i7505`; interface: `igc1` | about 10s while samples are present | Intel igc driver counters for LAN interface diagnostics | Driver watchdog events, CRC/symbol/receive errors, missed packets, RX overruns, drops, and link interrupt changes that may correlate with LAN instability |
| opnsense | `cpu` | `usage_guest`, `usage_guest_nice`, `usage_idle`, `usage_iowait`, `usage_irq`, `usage_nice`, `usage_softirq`, `usage_steal`, `usage_system`, `usage_user` | `cpu`, `host` | host: `gw01-i7505`; cpu: `cpu-total`, `cpu0`..`cpu3` | about 10s | OPNsense CPU utilization | Correlates routing/firewall stress with packet loss or latency |
| opnsense | `mem` | `active`, `available`, `available_percent`, `buffered`, `cached`, `free`, `inactive`, `laundry`, `total`, `used`, `used_percent`, `wired` | `host` | host: `gw01-i7505` | about 10s | OPNsense memory use | Correlates memory pressure with network instability |
| opnsense | `system` | `load1`, `load15`, `load5`, `n_cpus`, `n_physical_cpus`, `n_unique_users`, `n_users`, `uptime`, `uptime_format` | `host` | host: `gw01-i7505` | about 10s | Load and uptime | Correlates failures with reboot/uptime changes and host load |
| opnsense | `opnsense_temperature` | `value` | `host`, `sensor`, `type` | host: `gw01-i7505`; type: `cpu_core`, `acpi_zone`; sensor: `cpu0`..`cpu3`, `acpi_tz0` | about 10s | CPU and ACPI temperature telemetry | Correlates thermal issues with instability |
| opnsense | `processes` | `blocked`, `idle`, `running`, `sleeping`, `stopped`, `total`, `unknown`, `wait`, `zombies` | `host` | host: `gw01-i7505` | about 10s | Process state counts | Correlates process pressure with OPNsense responsiveness |
| opnsense | `swap` | `free`, `in`, `out`, `total`, `used`, `used_percent` | `host` | host: `gw01-i7505` | about 10s | Swap use | Correlates memory exhaustion with network failures |
| opnsense | `disk` | `free`, `inodes_free`, `inodes_total`, `inodes_used`, `inodes_used_percent`, `total`, `used`, `used_percent` | `device`, `fstype`, `host`, `mode`, `path` | host: `gw01-i7505` | about 10s | Filesystem capacity | General host health; not directly used for network fault isolation |
| opnsense | `diskio` | `io_await`, `io_svctm`, `io_time`, `io_util`, `iops_in_progress`, `merged_reads`, `merged_writes`, `read_bytes`, `read_time`, `reads`, `weighted_io_time`, `write_bytes`, `write_time`, `writes` | `host`, `name` | host: `gw01-i7505`; name: `nda0`, `pass0` | about 10s | Disk I/O | General host health; not directly used for network fault isolation |
| opnsense | `unbound` | `time_elapsed`, `time_now`, `time_up`, `total_num_cachehits`, `total_num_cachemiss`, `total_num_dns_error_reports`, `total_num_queries`, `total_num_queries_timed_out`, `total_requestlist_current_all`, `total_requestlist_exceeded`, `total_tcpusage`, and related Unbound counters | `host` | host: `gw01-i7505` | about 10s | DNS resolver counters | DNS resolver pressure and timeout correlation, but not packet-path isolation |
| opnsense | `unbound_threads` | `num_cachehits`, `num_cachemiss`, `num_dns_error_reports`, `num_queries`, `num_queries_timed_out`, `requestlist_current_all`, `requestlist_exceeded`, `tcpusage`, and related per-thread counters | `host`, `thread` | host: `gw01-i7505`; thread: `0`, `1`, `2`, `3` | about 10s | Per-thread DNS resolver counters | DNS resolver pressure and timeout correlation |

## Missing Metrics For The Requested Fault Isolation

- No `gateway` tag or gateway measurement was discovered, so WAN gateway status cannot be asserted from metrics.
- No external multi-target `ping` series was discovered; only CRS310 LAN control ping is present as `ping.url = 192.168.50.4`.
- No PF state metric was discovered.
- No explicit interface link state metric was discovered. `opnsense_igc.link_irq` can help correlate driver/link events, but it is not a direct up/down state.
- No CRS310 SNMP/interface telemetry was discovered.

## Recommended Telegraf Additions

- Add `inputs.ping` targets for WAN gateway, at least two public IP targets, and optionally a DNS-name target to separate routing from DNS issues.
- Add an OPNsense exec/API metric for gateway monitor status and PF state count/limit.
- Add interface link state collection for `igc0` and `igc1`.
- Add SNMP telemetry from MikroTik CRS310 for port status, errors, discards, and switch CPU/temperature.
- Add DNS probe metrics if Internet failures need DNS-vs-routing separation.

