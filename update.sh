#!/usr/bin/env bash
#
# Move the dsh backend to the latest published dsh, or check whether you should.
#
#   ./update.sh --check      # is a newer dsh published? exit 0 = current, 2 = update available
#   ./update.sh --apply      # backup, bump DSH_VERSION, rebuild, restart, verify
#   ./update.sh --plugin     re-resolve the Telegram adapter from its git ref
#   ./update.sh --rollback   go back to the version that was running before the last --apply
#   ./update.sh --status     what is installed / running / healthy
#
# Run it from this directory (next to compose.yaml and .env).
#
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=.env
COMPOSE=(docker compose)
BACKUP_DIR=backups
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-180}

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "no $ENV_FILE here — run from the compose directory"

env_get() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }
env_set() {
  local key=$1 value=$2
  if grep -q "^$key=" "$ENV_FILE"; then
    sed -i "s|^$key=.*|$key=$value|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

current_version() { env_get DSH_VERSION; }

latest_version() {
  local v
  v="$(curl -fsS --max-time 15 https://registry.npmjs.org/@deepseek-ai/dsh/latest 2>/dev/null \
        | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$v" ] || die "could not reach the npm registry"
  echo "$v"
}

container_health() {
  local state
  state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' dsh 2>/dev/null || true)"
  echo "${state:-missing}"
}

web_code() {
  local ip port code
  ip="$(env_get DSH_BIND_IP)"; port="$(env_get DSH_PORT)"
  [ -n "$ip" ] || ip=127.0.0.1
  [ -n "$port" ] || port=4310
  # a bare origin answers 401 on purpose: the runtime wants the ?token= URL
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${ip}:${port}/" 2>/dev/null || true)"
  echo "${code:-000}"
}

wait_healthy() {
  local waited=0 state
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    state="$(container_health)"
    case "$state" in
      healthy) return 0 ;;
      unhealthy|exited|dead) warn "container is $state"; return 1 ;;
    esac
    sleep 3; waited=$((waited + 3))
  done
  warn "container did not become healthy within ${HEALTH_TIMEOUT}s"; return 1
}

verify() {
  local code plugin_warn
  code="$(web_code)"
  case "$code" in
    200|302|303|401|403) log "web responds ($code) — runtime is up" ;;
    *) warn "web did not answer (code $code)"; return 1 ;;
  esac

  plugin_warn="$("${COMPOSE[@]}" logs --no-log-prefix --tail 200 dsh 2>/dev/null \
    | grep -i 'incompatible with dsh\|did not activate\|Adapter install failed' || true)"
  if [ -n "$plugin_warn" ]; then
    warn "the harness reported a plugin problem:"
    printf '%s\n' "$plugin_warn" | sed 's/^/    /'
    warn "run: ./update.sh --plugin"
    return 1
  fi
  log "no plugin compatibility complaints in the last 200 log lines"
}

backup_home() {
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  # sessions + profile config; the workspace is usually too big to copy here
  log "backing up data/home → $BACKUP_DIR/home-$stamp.tgz"
  tar czf "$BACKUP_DIR/home-$stamp.tgz" -C data home
  # keep the last 5
  ls -1t "$BACKUP_DIR"/home-*.tgz 2>/dev/null | tail -n +6 | xargs -r rm -f
}

apply_update() {
  local current latest
  current="$(current_version)"; latest="$(latest_version)"
  [ "$current" = "$latest" ] && { log "already on $latest"; return 0; }

  log "updating $current → $latest"
  backup_home
  env_set DSH_VERSION_PREVIOUS "$current"
  env_set DSH_VERSION "$latest"

  log "rebuilding (this also pulls a fresh base image)"
  "${COMPOSE[@]}" build --pull
  log "restarting"
  "${COMPOSE[@]}" up -d

  # the entrypoint re-grants the adapter's exact-version exemption on boot;
  # if the adapter cannot be mounted the verify step below says so
  if wait_healthy; then
    verify || warn "runtime is up but verification complained — check: docker compose logs dsh"
  else
    warn "update to $latest did not come up cleanly"
    warn "roll back with: ./update.sh --rollback"
    exit 1
  fi
  log "done — dsh $latest is running"
}

rollback() {
  local prev
  prev="$(env_get DSH_VERSION_PREVIOUS)"
  [ -n "$prev" ] || die "no DSH_VERSION_PREVIOUS recorded — nothing to roll back to"
  log "rolling back to $prev"
  env_set DSH_VERSION_PREVIOUS "$(current_version)"
  env_set DSH_VERSION "$prev"
  "${COMPOSE[@]}" build && "${COMPOSE[@]}" up -d
  wait_healthy && verify
}

status() {
  printf '%-22s %s\n' "compose version" "$(current_version)"
  printf '%-22s %s\n' "previous version" "$(env_get DSH_VERSION_PREVIOUS)"
  printf '%-22s %s\n' "latest published" "$(latest_version 2>/dev/null || echo '?')"
  printf '%-22s %s\n' "container" "$(container_health)"
  printf '%-22s %s\n' "web" "$(web_code)"
  printf '%-22s %s\n' "telegram adapter" "$(
    "${COMPOSE[@]}" exec -T dsh node -p "require('/data/home/profiles/web/node_modules/dsh-telegram/package.json').version" 2>/dev/null || echo 'not installed'
  )"
}

case "${1:---check}" in
  --check)
    cur="$(current_version)"; lat="$(latest_version)"
    if [ "$cur" = "$lat" ]; then
      log "up to date ($cur)"
      exit 0
    fi
    log "update available: $cur → $lat"
    exit 2
    ;;
  --apply)    apply_update ;;
  --rollback) rollback ;;
  --status)   status ;;
  --plugin)
    log "re-resolving the Telegram adapter"
    "${COMPOSE[@]}" run --rm dsh reset-plugin
    log "restarting"
    "${COMPOSE[@]}" up -d
    wait_healthy && verify
    ;;
  *)
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
