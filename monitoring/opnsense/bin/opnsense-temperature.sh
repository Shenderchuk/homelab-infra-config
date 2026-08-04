#!/bin/sh
set -eu

HOST="$(hostname -s)"

emit_temperature() {
  sensor="$1"
  type="$2"
  value="$3"
  device="${4:-}"

  if [ -z "$value" ]; then
    return 0
  fi

  if [ -n "$device" ]; then
    printf 'opnsense_temperature,host=%s,device=%s,sensor=%s,type=%s value=%s\n' \
      "$HOST" "$device" "$sensor" "$type" "$value"
    return 0
  fi

  printf 'opnsense_temperature,host=%s,sensor=%s,type=%s value=%s\n' \
    "$HOST" "$sensor" "$type" "$value"
}


sysctl -a 2>/dev/null | awk -F: '
  /^dev\.cpu\.[0-9]+\.temperature:/ {
    name=$1
    value=$2
    sub(/^dev\.cpu\./, "", name)
    sub(/\.temperature$/, "", name)
    gsub(/^[ \t]+|[ \t]+$/, "", value)
    sub(/C$/, "", value)
    printf "%s %s\n", name, value
  }
' | while read -r cpu value; do
  emit_temperature "cpu${cpu}" "cpu_core" "$value"
done

sysctl -a 2>/dev/null | awk -F: '
  /^hw\.acpi\.thermal\.tz[0-9]+\.temperature:/ {
    name=$1
    value=$2
    sub(/^hw\.acpi\.thermal\./, "", name)
    sub(/\.temperature$/, "", name)
    gsub(/^[ \t]+|[ \t]+$/, "", value)
    sub(/C$/, "", value)
    printf "%s %s\n", name, value
  }
' | while read -r zone value; do
  emit_temperature "acpi_${zone}" "acpi_zone" "$value"
done

if command -v nvmecontrol >/dev/null 2>&1; then
  for disk in $(sysctl -n kern.disks 2>/dev/null); do
    case "$disk" in
      nda*) ;;
      *) continue ;;
    esac

    nvmecontrol logpage -p 2 "$disk" 2>/dev/null | awk -v device="$disk" '
      /^Temperature:[[:space:]]/ {
        split($0, parts, ",")
        value=parts[2]
        gsub(/^[ \t]+|[ \t]+$/, "", value)
        sub(/[ \t]*C$/, "", value)
        if (value != "") {
          printf "nvme_composite nvme_composite %s %s\n", value, device
        }
      }
      /^Temperature Sensor [0-9]+:/ {
        sensor=$3
        sub(/:$/, "", sensor)
        split($0, parts, ",")
        value=parts[2]
        gsub(/^[ \t]+|[ \t]+$/, "", value)
        sub(/[ \t]*C$/, "", value)
        if (value != "") {
          printf "nvme_sensor%s nvme_sensor %s %s\n", sensor, value, device
        }
      }
    ' | while read -r sensor type value device; do
      emit_temperature "$sensor" "$type" "$value" "$device"
    done
  done
fi
