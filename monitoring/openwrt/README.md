# OpenWrt monitoring

The router gw02-i7505 runs Telegraf and sends metrics to the OpenWrt InfluxDB bucket. The tracked configuration is a template: populate its InfluxDB URL, organization, bucket and token securely on the router. The live service configuration may also contain site-specific settings; preserve those when updating it.

Install OpenWrt package `lm-sensors` and enable `inputs.sensors` in the active Telegraf configuration. It collects CPU package and core, NVMe, and ACPI readings when the kernel exposes them. Readings use measurement `sensors`, field `temp_input`, and `chip` and `feature` tags. Missing sensors produce no series. Validate with `sensors -j` and `telegraf --config /etc/telegraf.conf --test --input-filter sensors`.
