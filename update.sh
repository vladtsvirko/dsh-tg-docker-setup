#!/usr/bin/env bash
#
# Move the setup to a release tag; the DSH version moves with it.
#
#   ./update.sh              what is installed, and is it healthy (same as --status)
#   ./update.sh --check      what a compatible update would do; change nothing
#   ./update.sh --apply      latest compatible tag: checkout, install, health gate, rollback
#   ./update.sh --to <tag>   exact target (used by the updater service)
#   ./update.sh --tg-connector   re-resolve the pinned Telegram connector
#   ./update.sh --doctor     full health check; --fix repairs what it can
#   ./update.sh --component <name> <enable|disable|configure> [--port N]
#
# --yes (or ASSUME_YES=1) skips the confirmation. --check, --apply and --to also
# accept --i-know-versions-are-incompatible to cross a DSH line or a product
#
# Run it from this directory (next to VERSION and .env).
#
# Sourced by update.test.mjs to exercise the helpers below without running the
# CLI. Executed normally, nothing changes.
UPDATE_SOURCED=0
if [ "${BASH_SOURCE[0]}" != "$0" ]; then UPDATE_SOURCED=1; fi
if [ "$UPDATE_SOURCED" = 0 ]; then
  set -euo pipefail
  cd "$(dirname "$0")"
fi

ENV_FILE=.env
BACKUP_DIR=backups
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-180}

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  {
  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
  # A sourced caller must survive: the test asserts on the message, not on exit.
  if [ "${UPDATE_SOURCED:-0}" = 1 ]; then return 1; fi
  exit 1
}

if [ "$UPDATE_SOURCED" = 0 ]; then
  [ -f "$ENV_FILE" ] || die "no $ENV_FILE here — run from the deployment directory"
fi

env_get() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }
setup_version() { tr -d '\n' < VERSION; }
dsh_version() {
  local v
  v="$(setup_version)"
  printf '%s\n' "${v%-*}"
}

# --- firewall advisory (native only) ---------------------------------------
# Same contract as install.sh: ufw gates a systemd service through INPUT, and
# never gates a published Docker port (Docker DNATs it in nat/FORWARD before
# INPUT is consulted). Warn, never act.
#
# Kept in both files on purpose: install.sh is also fetched as a lone file, so a
# shared helper would break the `curl … | bash` bootstrap.

ufw_state() {
  if [ "$(id -u)" = 0 ]; then
    ufw status 2>/dev/null
    return 0
  fi
  # -n: a status run as a normal user must not sit waiting for a password.
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo -n ufw status 2>/dev/null
    return 0
  fi
  # Unprivileged without passwordless sudo: the rules are root-only, but the
  # enable flag is world-readable, so say "your firewall is on" anyway.
  if [ -r /etc/ufw/ufw.conf ] && grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
    printf 'Status: active\n'
    return 0
  fi
  return 1
}

# Whether the rules themselves are readable: a hint without them cannot claim a
# port is closed, only that ufw is on.
ufw_rules_readable() {
  [ "$(id -u)" = 0 ] && return 0
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null
}

# The network ufw wants ("allow from 10.0.0.0/8"), from a bind address.
lan_network() {
  local addr="$1" cidr="" prefix a b c d num mask net
  if command -v ip >/dev/null 2>&1; then
    cidr="$(ip -o -4 addr show scope global 2>/dev/null \
      | awk -v ip="$addr" '$4 ~ "^" ip "/" { print $4; exit }')"
  fi
  # Without an interface carrying the bind address, assume a /24 and still
  # print the network, not the host address.
  [ -n "$cidr" ] || cidr="$addr/24"
  addr="${cidr%/*}"
  prefix="${cidr##*/}"
  case "$addr" in ''|*[!0-9.]*) printf '%s\n' "$cidr"; return 0 ;; esac
  case "$prefix" in ''|*[!0-9]*) prefix=24 ;; esac
  if [ "$prefix" -lt 8 ] || [ "$prefix" -gt 32 ]; then prefix=24; fi
  IFS=. read -r a b c d <<<"$addr"
  num=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
  net=$(( num & mask ))
  printf '%d.%d.%d.%d/%d\n' $(( (net >> 24) & 255 )) $(( (net >> 16) & 255 )) \
    $(( (net >> 8) & 255 )) $(( net & 255 )) "$prefix"
}

# Warn for every (port, bind) pair on a non-loopback address that ufw does not
# allow. Silent when ufw is absent or inactive.
ufw_hints() {
  UFW_HINTED=0
  command -v ufw >/dev/null 2>&1 || return 0
  local status rules port bind net tunnel_port="" readable=1
  status="$(ufw_state | head -1)" || return 0
  [ "$status" = "Status: active" ] || return 0
  ufw_rules_readable || readable=0
  rules="$(ufw_state | sed -n 's/^\([0-9][0-9]*\)\(\/tcp\)\? *ALLOW.*/\1/p')"
  while [ "$#" -ge 2 ]; do
    port="$1"
    bind="$2"
    shift 2
    [ -n "$port" ] && [ -n "$bind" ] || continue
    case "$bind" in 127.*|localhost|::1) continue ;; esac
    if [ "$readable" = 1 ] && printf '%s\n' "$rules" | grep -qx "$port"; then continue; fi
    if [ "$UFW_HINTED" = 0 ]; then
      echo
      if [ "$readable" = 1 ]; then
        warn "ufw is active and does not allow the ports this deployment serves:"
      else
        warn "ufw is active (its rules need root to read); if a port is closed, allow it:"
      fi
    fi
    UFW_HINTED=1
    [ -n "$tunnel_port" ] || tunnel_port="$port"
    net="$(lan_network "$bind")"
    warn "  sudo ufw allow from $net to any port $port proto tcp    # $port on $bind"
  done
  if [ "$UFW_HINTED" = 1 ]; then
    warn "  or leave it closed and tunnel: ssh -L $tunnel_port:127.0.0.1:$tunnel_port <user>@<host>"
  fi
  return 0
}

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
# Used by `--tg-connector` and by the native apply path to run the entrypoint's
# prepare step without leaving root-owned files in the profile.
# The systemd unit runs the launcher from /usr/local/bin; a partial install may
# only have it inside the deployment directory. update.sh used to assume the
# latter existed in $DEPLOY_DIR, so every native update failed to prepare.
entrypoint_bin() {
  # DSH_ENTRYPOINT lets a test (or an unusual install) name the launcher.
  if [ -n "${DSH_ENTRYPOINT:-}" ] && [ -x "${DSH_ENTRYPOINT}" ]; then
    printf %s "$DSH_ENTRYPOINT"
  elif [ -x /usr/local/bin/dsh-entrypoint ]; then
    printf %s /usr/local/bin/dsh-entrypoint
  elif command -v dsh-entrypoint >/dev/null 2>&1; then
    command -v dsh-entrypoint
  elif [ -x "$DEPLOY_DIR/entrypoint.sh" ]; then
    printf %s "$DEPLOY_DIR/entrypoint.sh"
  else
    return 1
  fi
}

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
  # Run from the workspace directory, exactly as the systemd unit does. `dsh`
  # loads the .env of its working directory and refuses launch-only keys there
  # ("DSH_BIND_IP … export it instead"), so running this from the deployment
  # directory — the documented way — made every native prepare fail.
  local workdir="$NATIVE_DATA/workspace"
  [ -d "$workdir" ] || workdir=/
  ( cd "$workdir" && runuser -u "$SERVICE_USER" -- env "${pass[@]}" "$@" )
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
    npm install -g --silent \
      --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs \
      "@deepseek-ai/dsh@$target_dsh" pnpm@11 \
      || warn "could not install dsh $target_dsh — the health gate will decide"
  fi

  log "preparing the profile and the pinned connector"
  local entry
  if ! entry="$(entrypoint_bin)"; then
    warn "no entrypoint launcher in /usr/local/bin or $DEPLOY_DIR — rolling back to $cur"
    native_rollback "$cur" "$snapshot"
    return 1
  fi
  if ! run_as_service "$entry" init; then
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
  repair_deployment || warn "the update is applied, but the health check found something — ./update.sh --doctor"
  log "done — $target is running (detached HEAD)"
}


# The URL this process can reach the runtime at: the public root when one is
# configured, otherwise the bind address (127.0.0.1 is a real address here, not
# a published-port indirection).
web_probe_url() {
  local ip port public
  ip="$(env_get DSH_BIND_IP)"; port="$(env_get DSH_PORT)"; public="$(env_get DSH_PUBLIC_URL)"
  [ -n "$port" ] || port=4310
  if [ -n "$public" ]; then
    printf '%s' "$public"
    return 0
  fi
  [ -n "$ip" ] || ip=127.0.0.1
  printf 'http://%s:%s/' "$ip" "$port"
}

web_code() {
  local url code
  url="$(web_probe_url)"
  # a bare origin answers 401 on purpose: the runtime wants the ?token= URL
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" 2>/dev/null || true)"
  echo "${code:-000}"
}

web_ready() {
  case "$(web_code)" in
    200|302|303|401|403) return 0 ;;
  esac
  return 1
}


# --- setup repo updates, tag by tag --------------------------------------
# The setup repo is deployed at release tags, never off main. `--apply` moves to
# the latest compatible tag: skipping within the compatible line is allowed, a
# branch or a tag that is not a descendant is not. Rollback restores the
# previous checkout and the data snapshot.



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



self_update() {
  local allow=${1:-0} override=${2:-} override_allow=${3:-0} cur target all
  [ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash first"
  git fetch --tags --quiet origin || die "git fetch failed"
  cur="$(current_tag)" || die "cannot determine the deployed tag — check out the tag that is running"
  all="$(newer_tags)" || die "cannot list newer tags"

  if [ -n "$override" ]; then
    target="$override"
    [ "$target" != "$cur" ] || die "target is already running"
    grep -Fqx -- "$target" <<<"$all" || die "target $target is not a newer aligned tag"
    git merge-base --is-ancestor "$cur" "$target" || die "target $target is not a descendant of $cur"
    # --to is the raw explicit path, but it is not a policy bypass: the same
    # rule as --apply applies unless the caller says it means to cross. The
    # updater passes the flag only after its own /update check accepted it.
    if [ "$allow" != 1 ] && [ "$override_allow" != 1 ] &&
       { [ "$(tag_dsh "$target")" != "$(tag_dsh "$cur")" ] || [ "$(tag_major "$target")" != "$(tag_major "$cur")" ]; }; then
      die "target $target crosses a DSH line or a product major — pass --i-know-versions-are-incompatible"
    fi
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

  native_apply "$cur" "$target"
}

verify() {
  local code plugin_warn
  code="$(web_code)"
  case "$code" in
    200|302|303|401|403) log "web responds ($code) — runtime is up" ;;
    *) warn "web did not answer (code $code)"; return 1 ;;
  esac

  local since
  since="$(systemctl show -p ActiveEnterTimestamp --value dsh.service 2>/dev/null || true)"
  [ -n "$since" ] || since="-2 minutes"
  plugin_warn="$(journalctl -u dsh.service --no-pager --since "$since" 2>/dev/null \
    | grep -i 'incompatible with dsh\|did not activate\|Adapter install failed' || true)"
  if [ -n "$plugin_warn" ]; then
    warn "the harness reported a plugin problem:"
    printf '%s\n' "$plugin_warn" | sed 's/^/    /'
    warn "run: ./update.sh --tg-connector"
    return 1
  fi
  log "no plugin compatibility complaints since this start"
  # Native only, and silent unless ufw is active: after a port or bind change
  # the old rule is harmless but the new port is closed, which looks like a
  # broken update.
  ufw_hints "$(env_get DSH_PORT)" "$(env_get DSH_BIND_IP)"
}

# The same doctor install.sh runs, from the same file, in both modes. An update
# just rewrote .env and the profile, so this is the cheapest moment to catch a
# duplicated key or a credential the web UI stored that outranks it.
repair_deployment() {
  local script="$DEPLOY_DIR/scripts/repair.sh"
  [ -x "$script" ] || return 0
  bash "$script" --dir "$DEPLOY_DIR" --fix
}

status() {
  printf '%-22s %s
' "setup version" "$(setup_version)"
  printf '%-22s %s
' "dsh version" "$(dsh_version)"
  printf '%-22s %s
' "service" "$(systemctl is-active dsh.service 2>/dev/null || echo missing)"
  printf '%-22s %s
' "updater" "$(systemctl is-active dsh-updater.service 2>/dev/null || echo missing)"
  printf '%-22s %s
' "web" "$(web_code)"
  printf '%-22s %s
' "telegram adapter" "$(
    node -p "require('$NATIVE_DATA/home/profiles/web/node_modules/dsh-telegram-connector/package.json').version" 2>/dev/null || echo 'not installed'
  )"
  ufw_hints "$(env_get DSH_PORT)" "$(env_get DSH_BIND_IP)"
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
  systemctl restart dsh.service
}

component_running() {
  local dir=$1 file=$2
  podman-compose --project-directory "$dir" -f "$file" ps -q 2>/dev/null | grep -q .
}

component_health() {
  local url=$1 codes=$2 timeout=${3:-${COMPONENT_HEALTH_TIMEOUT:-60}} waited=0 code
  while [ "$waited" -lt "$timeout" ]; do
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

  local compose_file
  compose_file="$(basename "$(component_field "$name" compose)")"
  local running=0
  if component_running "$compose_dir" "$compose_dir/$compose_file"; then running=1; fi

  # Configuring a stopped stack is a preference, not a start: save the value and
  # leave the runtime alone. Only a running stack is recreated for a new port.
  if [ "$action" = configure ] && [ "$running" = 0 ]; then
    log "$name is not running; port $port saved — enable it to start"
    return 0
  fi

  case "$action" in
    enable|configure)
      log "starting $name on $bind:$port"
      ( cd "$compose_dir" && podman-compose -f "$compose_file" up -d ) || die "podman-compose failed for $name"
      set_env "$flag" 1 "$ENV_FILE"
      # The agent calls design/penpot.mjs from inside the runtime, so the
      # runtime environment needs the API root and the token.
      set_env PENPOT_ENABLED 1 "$ENV_FILE"
      local plugin_ref
      plugin_ref="$(node -e 'process.stdout.write(require("./components.json").components.design.plugin.ref)' 2>/dev/null || true)"
      if [ -n "$plugin_ref" ]; then set_env PENPOT_PLUGIN_REF "$plugin_ref" "$ENV_FILE"; fi
      set_env PENPOT_API_URL "http://$bind:$port" "$ENV_FILE"
      local token
      token="$(sed -n 's/^PENPOT_ACCESS_TOKEN=//p' "$env_file" | head -1)"
      if [ -n "$token" ]; then set_env PENPOT_ACCESS_TOKEN "$token" "$ENV_FILE"; fi
      log "restarting the runtime so the tools appear"
      restart_runtime || warn "could not restart the runtime"
      ;;
    disable)
      log "stopping $name (data stays in $compose_dir/data)"
      ( cd "$compose_dir" && podman-compose -f "$compose_file" down ) || warn "podman-compose down failed"
      set_env "$flag" 0 "$ENV_FILE"
      set_env PENPOT_ENABLED 0 "$ENV_FILE"
      set_env PENPOT_ACCESS_TOKEN "" "$ENV_FILE"
      log "restarting the runtime so the tools disappear"
      restart_runtime || warn "could not restart the runtime"
      ;;
  esac

  local codes
  codes="$(component_field "$name" health.codes | tr ',' ' ')"
  if [ "$action" != disable ]; then
    # The probe runs from the host against the published address. A failed
    # probe is advisory — compose already reported the containers up, and a host
    # firewall may block the path.
    local probe_url
    probe_url="$(printf '%s' "$(component_field "$name" health.url)" | sed -e "s/{bind}/$bind/" -e "s/{port}/$port/")"
    if component_health "$probe_url" "${codes:-200}"; then
      log "$name is up"
    else
      warn "$name containers are up, but $probe_url did not answer — check the port"
      ( cd "$compose_dir" && podman-compose -f "$compose_file" ps ) 2>/dev/null \
        | sed 's/^/    /' >&2 || true
    fi
  fi
}

if [ "$UPDATE_SOURCED" = 1 ]; then return 0; fi

# --yes is accepted anywhere and means the same as ASSUME_YES=1.
args=()
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    *) args+=("$arg") ;;
  esac
done
set -- "${args[@]}"

case "${1:---status}" in
  --status)   status ;;
  --doctor)
    doctor_fix=0
    if [ "${2:-}" = "--fix" ]; then doctor_fix=1
    elif [ -n "${2:-}" ]; then die "unknown option for --doctor: ${2}"; fi
    if [ ! -x "$DEPLOY_DIR/scripts/repair.sh" ]; then die "scripts/repair.sh is missing — reinstall with ./install.sh"; fi
    if [ "$doctor_fix" = 1 ]; then
      exec bash "$DEPLOY_DIR/scripts/repair.sh" --dir "$DEPLOY_DIR" --fix
    fi
    exec bash "$DEPLOY_DIR/scripts/repair.sh" --dir "$DEPLOY_DIR"
    ;;
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
  --tg-connector)
    log "re-resolving the Telegram connector"
    entry="$(entrypoint_bin)" || die "no entrypoint launcher found — reinstall with ./install.sh"
    run_as_service "$entry" reset-plugin
    systemctl restart dsh.service
    wait_native_healthy && verify
    ;;
  --check)
    if [ "${2:-}" = "--i-know-versions-are-incompatible" ]; then self_check 1
    elif [ -n "${2:-}" ]; then die "unknown option for --check: ${2}"
    else self_check 0; fi
    ;;
  --apply)
    if [ "${2:-}" = "--i-know-versions-are-incompatible" ]; then self_update 1
    elif [ -n "${2:-}" ]; then die "unknown option for --apply: ${2}"
    else self_update 0; fi
    ;;
  --to)
    [ -n "${2:-}" ] || die "usage: ./update.sh --to <tag> [--i-know-versions-are-incompatible]"
    case "${3:-}" in
      "") self_update 0 "$2" 0 ;;
      --i-know-versions-are-incompatible) self_update 0 "$2" 1 ;;
      *) die "unknown option for --to: ${3}" ;;
    esac
    ;;
  *)
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
