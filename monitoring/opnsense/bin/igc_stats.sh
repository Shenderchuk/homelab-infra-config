#!/bin/sh

IFACE_INDEX=1

printf 'opnsense_igc,interface=igc1 watchdog_timeouts=%si,link_irq=%si,crc_errs=%si,symbol_errors=%si,recv_errs=%si,missed_packets=%si,rx_overruns=%si,dropped=%si\n' \
  "$(sysctl -n dev.igc.${IFACE_INDEX}.watchdog_timeouts)" \
  "$(sysctl -n dev.igc.${IFACE_INDEX}.link_irq)" \
  "$(sysctl -n dev.igc.${IFACE_INDEX}.mac_stats.crc_errs)" \
  "$(sysctl -n dev.igc.${IFACE_INDEX}.mac_stats.symbol_errors)" \
  "$(sysctl -n dev.igc.${IFACE_INDEX}.mac_stats.recv_errs)" \
  "$(sysctl -n dev.igc.${IFACE_INDEX}.mac_stats.missed_packets)" \
  "$(sysctl -n dev.igc.${IFACE_INDEX}.rx_overruns)" \
  "$(sysctl -n dev.igc.${IFACE_INDEX}.dropped)"
