#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/infra-config}"
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-main}"
CADDY_SERVICE="${CADDY_SERVICE:-caddy}"
LOCK_FILE="${LOCK_FILE:-/run/caddy-gitops-sync.lock}"

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*"
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another sync is already running"
  exit 0
fi

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

tmp_dir="$(mktemp -d /tmp/caddy-gitops.XXXXXX)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

git archive "$target_head" | tar -x -C "$tmp_dir"

candidate_config="$tmp_dir/caddy/Caddyfile"
rewritten_config="$tmp_dir/Caddyfile"

# The production Caddyfile uses absolute imports. Rewrite those paths so
# validation checks the fetched candidate commit, not the currently deployed tree.
sed \
  -e "s#/opt/infra-config/caddy/#$tmp_dir/caddy/#g" \
  -e "s#/opt/homelab/infra-config/caddy/#$tmp_dir/caddy/#g" \
  "$candidate_config" > "$rewritten_config"

caddy validate --config "$rewritten_config"

git merge --ff-only "$target_head"
systemctl reload "$CADDY_SERVICE"

log "deployed $target_head and reloaded $CADDY_SERVICE"