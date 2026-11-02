#!/usr/bin/env bash
#
# Move the setup to a release tag; the DSH version moves with it.
#
#   ./update.sh --plugin     re-resolve the Telegram adapter from its git ref
#   ./update.sh --status     what is installed / running / healthy
#   ./update.sh --self-check # latest compatible tag? change nothing
#   ./update.sh --self [--i-know-versions-are-incompatible]
#                            # jump to the latest compatible tag, build, health gate, rollback
#   ./update.sh --self-to <tag>
#                            # exact target (used by the updater sidecar)
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
setup_version() { tr -d '\n' < VERSION; }
dsh_version() {
  local v
  v="$(setup_version)"
  printf '%s\n' "${v%-*}"
}

# --- deployment mode ------------------------------------------------------
# install.sh records MODE in .env. Older deployments have no MODE and are
# Docker; a native deploy is identified by its systemd unit.
MODE="${DSH_MODE:-$(env_get MODE)}"
if [ -z "$MODE" ]; then
  if [ -f /etc/systemd/system/dsh.service ] && ! docker inspect dsh >/dev/null 2>&1; then
    MODE=native
  else
    MODE=docker
  fi
fi
case "$MODE" in
  docker|native) ;;
  *) die "MODE=$MODE in $ENV_FILE — expected docker or native" ;;
esac
SERVICE_USER="${SERVICE_USER:-dsh}"
DEPLOY_DIR="$(pwd -P)"
NATIVE_DATA="$DEPLOY_DIR/data"

# Write one key into .env without touching anything else.
set_env() {
  local key="$1" value="$2" file="$3" tmp
  tmp="$(mktemp)"
  [ -f "$file" ] && grep -v "^${key}=" "$file" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
}

service_active() { systemctl is-active --quiet dsh.service 2>/dev/null; }

wait_native_healthy() {
  local waited=0
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    if service_active && web_ready; then return 0; fi
    sleep 3; waited=$((waited + 3))
  done
  warn "dsh.service did not become healthy within ${HEALTH_TIMEOUT}s"
  return 1
}

# Run a command as the unprivileged runtime user, with the deployment's env.
# Used by `--plugin` and by the native apply path to run the entrypoint's
# prepare step without leaving root-owned files in the profile.
run_as_service() {
  local -a pass=(
    "HOME=$NATIVE_DATA/home"
    "DSH_HOME=$NATIVE_DATA/home"
    "DSH_WORKSPACE=$NATIVE_DATA/workspace"
    "DSH_SUPERVISOR_STATE=$NATIVE_DATA/supervisor"
    "DSH_SETUP_VERSION=$(setup_version)"
  )
  local key value
  for key in DSH_PROVIDER DSH_MODEL DSH_PROVIDER_API_KEY_ENV OPENCODE_GO_API_KEY \
             DEEPSEEK_API_KEY DSH_TELEGRAM_BOT_TOKEN DSH_TELEGRAM_ENABLED \
             ALLOWED_USER_IDS DSH_PORT DSH_BIND_IP DSH_PUBLIC_URL DSH_PERMISSION_MODE; do
    value="$(env_get "$key")"
    [ -n "$value" ] && pass+=("$key=$value")
  done
  runuser -u "$SERVICE_USER" -- env "${pass[@]}" "$@"
}

native_snapshot() {
  local stamp=$1 file
  [ -d "$NATIVE_DATA/home" ] || return 1
  mkdir -p "$BACKUP_DIR"
  file="$BACKUP_DIR/self-$stamp.tgz"
  local paths=(home)
  [ -d "$NATIVE_DATA/supervisor" ] && paths+=(supervisor)
  tar czf "$file" -C "$NATIVE_DATA" "${paths[@]}"
  ls -1t "$BACKUP_DIR"/self-*.tgz 2>/dev/null | tail -n +2 | while IFS= read -r old; do rm -f "$old"; done
  printf '%s\n' "$file"
}

native_restore() {
  local file=$1
  [ -f "$file" ] || return 1
  rm -rf "$NATIVE_DATA/home" "$NATIVE_DATA/supervisor"
  tar xzf "$file" -C "$NATIVE_DATA"
  chown -R "$SERVICE_USER:$SERVICE_USER" "$NATIVE_DATA/home" 2>/dev/null || true
  [ -d "$NATIVE_DATA/supervisor" ] && chown -R "$SERVICE_USER:$SERVICE_USER" "$NATIVE_DATA/supervisor" 2>/dev/null || true
}

native_rollback() {
  local cur=$1 snapshot=$2
  git -c advice.detachedHead=false checkout --detach "$cur" >/dev/null 2>&1 \
    || warn "could not check out $cur"
  set_env DSH_SETUP_VERSION "${cur#v}" "$ENV_FILE"
  chown "root:$SERVICE_USER" "$ENV_FILE" 2>/dev/null || true
  chmod 640 "$ENV_FILE" 2>/dev/null || true
  if [ -n "$snapshot" ]; then native_restore "$snapshot" || warn "data restore failed — the snapshot is at $snapshot"; fi
  systemctl restart dsh.service || warn "could not restart dsh.service"
  if wait_native_healthy; then
    verify || warn "rolled back, but verification complained — inspect: journalctl -u dsh.service"
    warn "rolled back to $cur; the previous setup is running"
    return 1
  fi
  die "rollback failed too — $snapshot remains for recovery"
}

# Native apply: same tag policy as Docker, but the "artifact" is the checkout
# plus the connector it installs, and the restart belongs to systemd.
native_apply() {
  local cur=$1 target=$2 snapshot=""
  log "snapshotting data/home and data/supervisor"
  if ! snapshot="$(native_snapshot "$(date +%Y%m%d-%H%M%S)")"; then
    warn "snapshot failed; the deployment was not touched"
    return 1
  fi
  log "snapshot: $snapshot"

  log "checking out $target"
  if ! git -c advice.detachedHead=false checkout --detach "$target"; then
    warn "checkout failed; still on $cur"
    return 1
  fi
  set_env DSH_SETUP_VERSION "${target#v}" "$ENV_FILE"
  chown "root:$SERVICE_USER" "$ENV_FILE" 2>/dev/null || true
  chmod 640 "$ENV_FILE" 2>/dev/null || true

  local target_dsh
  target_dsh="$(tag_dsh "$target")"
  if ! command -v dsh >/dev/null 2>&1 || \
     [ "$(dsh --version 2>/dev/null | tr -d 'v[:space:]')" != "$target_dsh" ]; then
    log "installing @deepseek-ai/dsh@$target_dsh"
    npm install -g --silent "@deepseek-ai/dsh@$target_dsh" \
      || warn "could not install dsh $target_dsh — the health gate will decide"
  fi

  log "preparing the profile and the pinned connector"
  if ! run_as_service "$DEPLOY_DIR/dsh-entrypoint" init; then
    warn "prepare failed — rolling back to $cur"
    native_rollback "$cur" "$snapshot"
    return 1
  fi

  log "restarting dsh.service"
  if ! systemctl restart dsh.service; then
    warn "restart failed — rolling back to $cur"
    native_rollback "$cur" "$snapshot"
    return 1
  fi

  if ! wait_native_healthy; then
    warn "new tag did not become healthy; rolling back to $cur"
    native_rollback "$cur" "$snapshot"
    return 1
  fi

  verify || warn "healthy, but verification complained — inspect: journalctl -u dsh.service"
  log "done — $target is running (detached HEAD)"
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

web_ready() {
  case "$(web_code)" in
    200|302|303|401|403) return 0 ;;
  esac
  return 1
}

wait_healthy() {
  local waited=0 state
  if [ "$MODE" = native ]; then wait_native_healthy; return $?; fi
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

# The container can report healthy on a TCP accept before the web app has
# finished dispatching, so allow a short settle window instead of one probe.
wait_web() {
  local waited=0 limit=${WEB_READY_TIMEOUT:-30}
  while [ "$waited" -lt "$limit" ]; do
    if web_ready; then return 0; fi
    sleep 2; waited=$((waited + 2))
  done
  return 1
}


# --- setup repo updates, tag by tag --------------------------------------
# The setup repo is deployed at release tags, never off main. `--self` moves to
# the immediate successor tag only: no skipping, no jumping branches. Rollback
# restores both the checkout and the image that was running.

image_ref() {
  printf 'dsh-backend:%s\n' "$(setup_version)"
}

start_and_wait() {
  local recreate=${1:-}
  local require_web=${2:-1}
  local extra=()
  [ "$recreate" = force ] && extra=(--force-recreate)
  if "${COMPOSE[@]}" up --help 2>&1 | grep -q -- '--wait-timeout'; then
    "${COMPOSE[@]}" up -d "${extra[@]}" --wait --wait-timeout "$HEALTH_TIMEOUT" dsh || return 1
  else
    "${COMPOSE[@]}" up -d "${extra[@]}" dsh || return 1
    wait_healthy || return 1
  fi
  # The container can be healthy while the published port points at the wrong
  # container interface. That is not a usable update.
  if [ "$require_web" = 1 ] && ! wait_web; then
    warn "container is healthy but the published web UI did not answer (code $(web_code))"
    return 1
  fi
}

# The tag checked out right now. A deploy box must be on a tag, not main.
current_tag() {
  local tag
  tag="$(git describe --tags --exact-match 2>/dev/null)" || {
    warn "this checkout is not on a release tag — check out the tag you deploy"
    return 1
  }
  printf '%s\n' "$tag"
}

# v0.2.1-rc.2-0.1.0 → 0.2.1-rc.2 (everything before the last -X.Y.Z).
tag_dsh() {
  local t=${1#v}
  printf '%s\n' "${t%-*}"
}

# v0.2.1-rc.2-0.1.0 → 0.0.1
tag_product() {
  local t=${1#v}
  printf '%s\n' "${t##*-}"
}

tag_major() {
  local product
  product="$(tag_product "$1")"
  printf '%s\n' "${product%%.*}"
}

# Every valid aligned tag newer than the current one, oldest first.
newer_tags() {
  local cur tags line found=0
  cur="$(current_tag)" || return 1
  tags="$(git -c versionsort.suffix=-rc tag --list 'v*' --sort=v:refname \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?-[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  if ! grep -Fqx -- "$cur" <<<"$tags"; then
    warn "current tag $cur is not a <dsh>-<major>.<minor>.<patch> tag"
    return 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$found" = 1 ] && printf '%s\n' "$line"
    [ "$line" = "$cur" ] && found=1
  done <<<"$tags"
  return 0
}

# Latest tag the updater may move to. Without the explicit flag this stays on
# the same DSH line and the same product major; with it, the latest tag wins.
target_tag() {
  local allow=${1:-0} cur cur_dsh cur_major tag last=""
  cur="$(current_tag)" || return 1
  cur_dsh="$(tag_dsh "$cur")"
  cur_major="$(tag_major "$cur")"
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    git merge-base --is-ancestor "$cur" "$tag" || continue
    if [ "$allow" != 1 ]; then
      [ "$(tag_dsh "$tag")" = "$cur_dsh" ] || continue
      [ "$(tag_major "$tag")" = "$cur_major" ] || continue
    fi
    last="$tag"
  done < <(newer_tags)
  [ -n "$last" ] || return 1
  printf '%s\n' "$last"
}

self_check() {
  local allow=${1:-0} cur target all
  git fetch --tags --quiet origin || die "git fetch failed"
  cur="$(current_tag)" || die "cannot determine the deployed tag — check out the tag that is running"
  all="$(newer_tags)" || die "cannot list newer tags"
  if [ -z "$all" ]; then
    log "no newer tag after $cur"
    exit 0
  fi
  target="$(target_tag "$allow" || true)"
  if [ -z "$target" ]; then
    warn "no compatible tag after $cur"
    warn "crossing a product major or a DSH line requires --i-know-versions-are-incompatible"
    printf '%s\n' "$all" | sed 's/^/    /'
    exit 2
  fi
  log "current tag: $cur"
  log "target tag:  $target  (latest compatible)"
  log "available:   $(printf '%s\n' "$all" | tr '\n' ' ')"
  git --no-pager log --oneline "$cur..$target" | sed 's/^/    /'
  exit 2
}

snapshot_state() {
  local stamp=$1
  local file="$BACKUP_DIR/self-$stamp.tgz"
  [ -d data/home ] || return 1
  mkdir -p "$BACKUP_DIR"
  local paths=(home)
  [ -d data/supervisor ] && paths+=(supervisor)
  tar czf "$file" -C data "${paths[@]}"
  # one rollback snapshot is enough (portable: no xargs -r in busybox)
  ls -1t "$BACKUP_DIR"/self-*.tgz 2>/dev/null | tail -n +2 | while IFS= read -r old; do rm -f "$old"; done
  printf '%s\n' "$file"
}

restore_state() {
  local file=$1 uid gid
  [ -f "$file" ] || return 1
  uid="$(env_get DSH_UID)"; uid="${uid:-1000}"
  gid="$(env_get DSH_GID)"; gid="${gid:-1000}"
  rm -rf data/home data/supervisor
  tar xzf "$file" -C data
  chown -R "$uid:$gid" data/home 2>/dev/null || true
  [ -d data/supervisor ] && chown -R "$uid:$gid" data/supervisor 2>/dev/null || true
}

self_update() {
  local allow=${1:-0} override=${2:-} cur target all prev_image snapshot
  [ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash first"
  git fetch --tags --quiet origin || die "git fetch failed"
  cur="$(current_tag)" || die "cannot determine the deployed tag — check out the tag that is running"
  all="$(newer_tags)" || die "cannot list newer tags"

  if [ -n "$override" ]; then
    target="$override"
    [ "$target" != "$cur" ] || die "target is already running"
    grep -Fqx -- "$target" <<<"$all" || die "target $target is not a newer aligned tag"
    git merge-base --is-ancestor "$cur" "$target" || die "target $target is not a descendant of $cur"
  else
    if [ -z "$all" ]; then
      log "no newer tag after $cur — nothing to do"
      return 0
    fi
    target="$(target_tag "$allow" || true)"
    if [ -z "$target" ]; then
      warn "no compatible tag after $cur"
      warn "crossing a product major or a DSH line requires --i-know-versions-are-incompatible"
      return 1
    fi
  fi

  log "setup update: $cur → $target"
  git --no-pager log --oneline "$cur..$target" | sed 's/^/    /'
  if [ "${ASSUME_YES:-0}" != 1 ]; then
    read -r -p "apply? [y/N] " answer
    [ "$answer" = y ] || { log "cancelled"; return 0; }
  fi

  if [ "$MODE" = native ]; then
    native_apply "$cur" "$target"
    return $?
  fi

  prev_image="$(docker inspect --format '{{.Image}}' dsh 2>/dev/null || true)"
  [ -n "$prev_image" ] || die "cannot find the running dsh container"
  docker tag "$prev_image" dsh-backend:self-previous
  log "saved current image as dsh-backend:self-previous"

  log "checking out $target"
  git -c advice.detachedHead=false checkout --detach "$target" || {
    warn "checkout failed; still on $cur"
    return 1
  }

  log "building dsh"
  if ! "${COMPOSE[@]}" build dsh; then
    warn "build failed — restoring $cur; the old container was not touched"
    git -c advice.detachedHead=false checkout --detach "$cur" >/dev/null 2>&1 || true
    return 1
  fi

  log "stopping dsh (freeze)"
  if ! "${COMPOSE[@]}" stop dsh; then
    warn "could not stop dsh; restoring $cur"
    git -c advice.detachedHead=false checkout --detach "$cur" >/dev/null 2>&1 || true
    return 1
  fi

  log "snapshotting data/home and data/supervisor"
  if ! snapshot="$(snapshot_state "$(date +%Y%m%d-%H%M%S)")"; then
    warn "snapshot failed; restarting the previous setup"
    "${COMPOSE[@]}" stop dsh >/dev/null 2>&1 || true
    git -c advice.detachedHead=false checkout --detach "$cur" >/dev/null 2>&1 || true
    docker tag dsh-backend:self-previous "$(image_ref)"
    start_and_wait force 0 || die "could not restart the previous setup"
    die "snapshot failed; previous setup restored"
  fi
  log "snapshot: $snapshot"

  log "starting dsh"
  if ! start_and_wait; then
    warn "new tag did not become healthy; rolling back to $cur"
    "${COMPOSE[@]}" stop dsh >/dev/null 2>&1 || true
    restore_state "$snapshot" || warn "data restore failed — the snapshot is at $snapshot"
    git -c advice.detachedHead=false checkout --detach "$cur" >/dev/null 2>&1 || true
    docker tag dsh-backend:self-previous "$(image_ref)"
    if start_and_wait force 0; then
      verify || warn "rolled back, but verification complained — inspect: docker compose logs dsh"
      warn "rolled back to $cur; the previous setup is running"
      return 1
    fi
    die "rollback failed too — dsh-backend:self-previous and $snapshot remain for recovery"
  fi

  verify || warn "healthy, but verification complained — inspect: docker compose logs dsh"
  log "done — $target is running (detached HEAD)"
}

verify() {
  local code plugin_warn
  code="$(web_code)"
  case "$code" in
    200|302|303|401|403) log "web responds ($code) — runtime is up" ;;
    *) warn "web did not answer (code $code)"; return 1 ;;
  esac

  if [ "$MODE" = native ]; then
    plugin_warn="$(journalctl -u dsh.service --no-pager -n 200 2>/dev/null \
      | grep -i 'incompatible with dsh\|did not activate\|Adapter install failed' || true)"
  else
    plugin_warn="$("${COMPOSE[@]}" logs --no-log-prefix --tail 200 dsh 2>/dev/null \
      | grep -i 'incompatible with dsh\|did not activate\|Adapter install failed' || true)"
  fi
  if [ -n "$plugin_warn" ]; then
    warn "the harness reported a plugin problem:"
    printf '%s\n' "$plugin_warn" | sed 's/^/    /'
    warn "run: ./update.sh --plugin"
    return 1
  fi
  log "no plugin compatibility complaints in the last 200 log lines"
}

status() {
  printf '%-22s %s\n' "mode" "$MODE"
  printf '%-22s %s\n' "setup version" "$(setup_version)"
  printf '%-22s %s\n' "dsh version" "$(dsh_version)"
  if [ "$MODE" = native ]; then
    printf '%-22s %s\n' "service" "$(systemctl is-active dsh.service 2>/dev/null || echo missing)"
    printf '%-22s %s\n' "updater" "$(systemctl is-active dsh-updater.service 2>/dev/null || echo missing)"
  else
    printf '%-22s %s\n' "container" "$(container_health)"
  fi
  printf '%-22s %s\n' "web" "$(web_code)"
  if [ "$MODE" = native ]; then
    printf '%-22s %s\n' "telegram adapter" "$(
      node -p "require('$NATIVE_DATA/home/profiles/web/node_modules/dsh-telegram-connector/package.json').version" 2>/dev/null || echo 'not installed'
    )"
  else
    printf '%-22s %s\n' "telegram adapter" "$(
      "${COMPOSE[@]}" exec -T dsh node -p "require('/data/home/profiles/web/node_modules/dsh-telegram-connector/package.json').version" 2>/dev/null || echo 'not installed'
    )"
  fi
}

# --- components ------------------------------------------------------------
# Optional stacks registered in components.json (the design stack today). The
# updater calls this with a validated name, action and config, so the shell does
# the mechanics and the registry stays the single source of truth.

component_field() {
  local name=$1 expr=$2
  node -e '
    const [name, expr] = process.argv.slice(1)
    const c = require("./components.json").components[name]
    if (!c) process.exit(2)
    const value = expr.split(".").reduce((o, k) => (o == null ? o : o[k]), c)
    process.stdout.write(value == null ? "" : String(value))
  ' "$name" "$expr"
}

component_names() {
  node -e 'process.stdout.write(Object.keys(require("./components.json").components).join(" "))'
}

restart_runtime() {
  if [ "$MODE" = native ]; then
    systemctl restart dsh.service
  else
    "${COMPOSE[@]}" restart dsh
  fi
}

component_health() {
  local url=$1 codes=$2 waited=0 code
  while [ "$waited" -lt 300 ]; do
    code="$(curl -s -o /dev/null -m 4 -w '%{http_code}' "$url" 2>/dev/null || true)"
    case " $codes " in *" $code "*) return 0 ;; esac
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

component_apply() {
  local name=$1 action=$2 port=${3:-}
  local names
  names="$(component_names 2>/dev/null || true)"
  case " $names " in
    *" $name "*) ;;
    *) die "unknown component: $name (known: ${names:-none})" ;;
  esac
  case "$action" in enable|disable|configure) ;; *) die "unknown action: $action" ;; esac

  local compose_dir env_file template flag
  compose_dir="$(component_field "$name" projectDir)"
  env_file="$(component_field "$name" envFile)"
  template="$(component_field "$name" template)"
  flag="$(component_field "$name" flag)"
  [ -n "$compose_dir" ] && [ -n "$env_file" ] || die "components.json entry for $name is incomplete"

  if [ -n "$port" ]; then
    case "$port" in ''|*[!0-9]*) die "port must be a number" ;; esac
    [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || die "port must be between 1024 and 65535"
  fi

  if [ ! -f "$env_file" ]; then
    [ "$action" = disable ] && { log "$name is not installed; nothing to disable"; return 0; }
    [ -f "$template" ] || die "no $env_file and no $template to create it from"
    mkdir -p "$compose_dir"
    cp "$template" "$env_file"
    set_env PENPOT_DB_PASSWORD "$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')" "$env_file"
    set_env PENPOT_SECRET_KEY "$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" "$env_file"
    chmod 600 "$env_file"
  fi

  local bind port_default
  bind="$(env_get DSH_BIND_IP)"; [ -n "$bind" ] || bind=127.0.0.1
  port_default="$(component_field "$name" config.port.default)"
  [ -n "$port" ] || port="$(sed -n "s/^$(component_field "$name" config.port.env)=//p" "$env_file" | head -1)"
  [ -n "$port" ] || port="$port_default"

  local port_key
  port_key="$(component_field "$name" config.port.env)"
  set_env DSH_BIND_IP "$bind" "$env_file"
  if [ -n "$port_key" ]; then set_env "$port_key" "$port" "$env_file"; fi

  case "$action" in
    enable|configure)
      log "starting $name on $bind:$port"
      docker compose --project-directory "$compose_dir" -f "$compose_dir/$(basename "$(component_field "$name" compose)")" up -d --build || die "docker compose failed for $name"
      set_env "$flag" 1 "$ENV_FILE"
      # The agent calls design/penpot.mjs from inside the runtime, so the
      # runtime environment needs the API root and the token.
      set_env PENPOT_API_URL "http://$bind:$port" "$ENV_FILE"
      local token
      token="$(sed -n 's/^PENPOT_ACCESS_TOKEN=//p' "$env_file" | head -1)"
      if [ -n "$token" ]; then set_env PENPOT_ACCESS_TOKEN "$token" "$ENV_FILE"; fi
      log "restarting the runtime so the tools appear"
      restart_runtime || warn "could not restart the runtime"
      ;;
    disable)
      log "stopping $name (data stays in $compose_dir/data)"
      docker compose --project-directory "$compose_dir" -f "$compose_dir/$(basename "$(component_field "$name" compose)")" down || warn "docker compose down failed"
      set_env "$flag" 0 "$ENV_FILE"
      set_env PENPOT_ACCESS_TOKEN "" "$ENV_FILE"
      log "restarting the runtime so the tools disappear"
      restart_runtime || warn "could not restart the runtime"
      ;;
  esac

  local codes
  codes="$(component_field "$name" health.codes | tr ',' ' ')"
  if [ "$action" != disable ]; then
    if ! component_health "$(printf '%s' "$(component_field "$name" health.url)" | sed -e "s/{bind}/$bind/" -e "s/{port}/$port/")" "${codes:-200}"; then
      warn "$name did not answer within 5 minutes"
      return 1
    fi
    log "$name is up"
  fi
}

case "${1:---status}" in
  --status)   status ;;
  --component)
    comp_name="${2:-}"; comp_action="${3:-enable}"; comp_port=""
    [ -n "$comp_name" ] || die "usage: ./update.sh --component <name> <enable|disable|configure> [--port N]"
    shift 2 || true
    [ $# -gt 0 ] && shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --port) comp_port="${2:-}"; shift 2 ;;
        *) die "unknown option for --component: $1" ;;
      esac
    done
    component_apply "$comp_name" "$comp_action" "$comp_port"
    ;;
  --plugin)
    log "re-resolving the Telegram adapter"
    if [ "$MODE" = native ]; then
      run_as_service "$DEPLOY_DIR/dsh-entrypoint" reset-plugin
      systemctl restart dsh.service
      wait_native_healthy && verify
    else
      "${COMPOSE[@]}" run --rm dsh reset-plugin
      log "restarting"
      "${COMPOSE[@]}" up -d dsh
      wait_healthy && verify
    fi
    ;;
  --self-check)
    if [ "${2:-}" = "--i-know-versions-are-incompatible" ]; then self_check 1
    elif [ -n "${2:-}" ]; then die "unknown option for --self-check: ${2}"
    else self_check 0; fi
    ;;
  --self)
    if [ "${2:-}" = "--i-know-versions-are-incompatible" ]; then self_update 1
    elif [ -n "${2:-}" ]; then die "unknown option for --self: ${2}"
    else self_update 0; fi
    ;;
  --self-to)
    [ -n "${2:-}" ] || die "usage: ./update.sh --self-to <tag>"
    self_update 0 "$2"
    ;;
  *)
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
