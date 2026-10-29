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


# --- setup repo updates, tag by tag --------------------------------------
# The setup repo is deployed at release tags, never off main. `--self` moves to
# the immediate successor tag only: no skipping, no jumping branches. Rollback
# restores both the checkout and the image that was running.

image_ref() {
  printf 'dsh-backend:%s\n' "$(setup_version)"
}

start_and_wait() {
  local recreate=${1:-}
  local extra=()
  [ "$recreate" = force ] && extra=(--force-recreate)
  if "${COMPOSE[@]}" up --help 2>&1 | grep -q -- '--wait-timeout'; then
    "${COMPOSE[@]}" up -d "${extra[@]}" --wait --wait-timeout "$HEALTH_TIMEOUT" dsh
  else
    "${COMPOSE[@]}" up -d "${extra[@]}" dsh
    wait_healthy
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
    start_and_wait force || die "could not restart the previous setup"
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
    if start_and_wait force; then
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

status() {
  printf '%-22s %s\n' "setup version" "$(setup_version)"
  printf '%-22s %s\n' "dsh version" "$(dsh_version)"
  printf '%-22s %s\n' "container" "$(container_health)"
  printf '%-22s %s\n' "web" "$(web_code)"
  printf '%-22s %s\n' "telegram adapter" "$(
    "${COMPOSE[@]}" exec -T dsh node -p "require('/data/home/profiles/web/node_modules/dsh-telegram/package.json').version" 2>/dev/null || echo 'not installed'
  )"
}

case "${1:---status}" in
  --status)   status ;;
  --plugin)
    log "re-resolving the Telegram adapter"
    "${COMPOSE[@]}" run --rm dsh reset-plugin
    log "restarting"
    "${COMPOSE[@]}" up -d dsh
    wait_healthy && verify
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
