#!/bin/sh
set -eu

REPO_DIR="${REPO_DIR:-/opt/infra-config}"
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-main}"
TELEGRAF_BASE_CONFIG="${TELEGRAF_BASE_CONFIG:-/usr/local/etc/telegraf.conf}"
TELEGRAF_CONFDIR="${TELEGRAF_CONFDIR:-/usr/local/etc/telegraf.d}"
SCRIPT_DIR="${SCRIPT_DIR:-/usr/local/bin}"
TELEGRAF_SERVICE="${TELEGRAF_SERVICE:-telegraf}"

REPO_OPNSENSE_DIR="monitoring/opnsense"
MANAGED_CONF_FILES="cpu-temperature.conf igc_stats.conf"
MANAGED_SCRIPT_FILES="opnsense-temperature.sh igc_stats.sh"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

copy_if_present() {
  src="$1"
  dst="$2"

  if [ -e "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
  fi
}

restore_backup() {
  backup_dir="$1"

  for name in $MANAGED_CONF_FILES; do
    if [ -e "$backup_dir/telegraf.d/$name" ]; then
      install -o telegraf -g telegraf -m 0644 "$backup_dir/telegraf.d/$name" "$TELEGRAF_CONFDIR/$name"
    fi
  done

  for name in $MANAGED_SCRIPT_FILES; do
    if [ -e "$backup_dir/bin/$name" ]; then
      install -o root -g wheel -m 0755 "$backup_dir/bin/$name" "$SCRIPT_DIR/$name"
    fi
  done
}

validate_candidate() {
  root_dir="$1"
  candidate_dir="$root_dir/$REPO_OPNSENSE_DIR"
  validation_confdir="$root_dir/validation-telegraf.d"

  for script in "$candidate_dir/bin/"*.sh; do
    [ -e "$script" ] || continue
    sh -n "$script"
  done

  mkdir -p "$validation_confdir"
  for conf in "$candidate_dir/telegraf.d/"*.conf; do
    [ -e "$conf" ] || continue
    sed "s#/usr/local/bin/#$candidate_dir/bin/#g" "$conf" > "$validation_confdir/$(basename "$conf")"
  done

  telegraf config check --config "$TELEGRAF_BASE_CONFIG" --config-directory "$validation_confdir"
}

install_candidate() {
  candidate_dir="$1"

  install -d -o telegraf -g telegraf -m 0750 "$TELEGRAF_CONFDIR"
  install -d -o root -g wheel -m 0755 "$SCRIPT_DIR"

  for name in $MANAGED_CONF_FILES; do
    install -o telegraf -g telegraf -m 0644 "$candidate_dir/telegraf.d/$name" "$TELEGRAF_CONFDIR/$name"
  done

  for name in $MANAGED_SCRIPT_FILES; do
    install -o root -g wheel -m 0755 "$candidate_dir/bin/$name" "$SCRIPT_DIR/$name"
  done
}

cd "$REPO_DIR"

git fetch --prune "$REMOTE" "$BRANCH"
current_head="$(git rev-parse HEAD)"
target_head="$(git rev-parse "$REMOTE/$BRANCH")"

if [ "$current_head" = "$target_head" ]; then
  log "already up to date at $current_head"
  exit 0
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  log "working tree is dirty; refusing to deploy"
  git status --short
  exit 1
fi

tmp_dir="$(mktemp -d /tmp/opnsense-telegraf-gitops.XXXXXX)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

git archive "$target_head" | tar -x -C "$tmp_dir"
validate_candidate "$tmp_dir"

backup_dir="$tmp_dir/backup"
for name in $MANAGED_CONF_FILES; do
  copy_if_present "$TELEGRAF_CONFDIR/$name" "$backup_dir/telegraf.d/$name"
done
for name in $MANAGED_SCRIPT_FILES; do
  copy_if_present "$SCRIPT_DIR/$name" "$backup_dir/bin/$name"
done

git merge --ff-only "$target_head"
candidate_dir="$REPO_DIR/$REPO_OPNSENSE_DIR"

if ! install_candidate "$candidate_dir"; then
  log "install failed; restoring previous managed files"
  restore_backup "$backup_dir"
  exit 1
fi

if ! telegraf config check --config "$TELEGRAF_BASE_CONFIG" --config-directory "$TELEGRAF_CONFDIR"; then
  log "active telegraf config check failed; restoring previous managed files"
  restore_backup "$backup_dir"
  telegraf config check --config "$TELEGRAF_BASE_CONFIG" --config-directory "$TELEGRAF_CONFDIR" || true
  exit 1
fi

if ! service "$TELEGRAF_SERVICE" restart; then
  log "telegraf restart failed; restoring previous managed files"
  restore_backup "$backup_dir"
  telegraf config check --config "$TELEGRAF_BASE_CONFIG" --config-directory "$TELEGRAF_CONFDIR" || true
  service "$TELEGRAF_SERVICE" restart || true
  exit 1
fi

log "deployed $target_head and restarted $TELEGRAF_SERVICE"
