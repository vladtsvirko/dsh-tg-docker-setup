#!/usr/bin/env bash
#
# One-command installer for the DSH setup, in either mode.
#
#   ./install.sh                        interactive: asks for the few values
#                                        that are easy to get wrong
#   ./install.sh --check                print the plan, change nothing
#   ./install.sh --mode native --yes    unattended, native (no Docker)
#   ./install.sh --config answers.env   answers from a file (see install.example.env)
#
# docker mode  compose.yaml: init + dsh + the privileged updater sidecar.
#              The container is the security boundary; the agent cannot reach
#              the host, so the web UI and Telegram are the only control paths.
# native mode  a systemd service on this host, no Docker at all. The agent runs
#              as an unprivileged user and can reach the host's files; the
#              updater runs as root because only it may restart the service.
#              Read docs/HOST.md before choosing it.
#
# Everything the installer decides is printed as a plan first. With --check the
# plan is all that happens, which is what the test suite exercises.
set -euo pipefail

cd "$(dirname "$0")"
SRC_DIR="$(pwd -P)"
SETUP_VERSION="$(tr -d '\n' < "$SRC_DIR/VERSION")"
DSH_VERSION="$(printf '%s' "$SETUP_VERSION" | sed -E 's/-[0-9]+\.[0-9]+\.[0-9]+$//')"

MODE="" TIER="" DIR="" CONFIG="" REF="" CHECK=0 YES=0 UNINSTALL=0 PURGE=0
SERVICE_USER="${SERVICE_USER:-dsh}"
DSH_PORT="${DSH_PORT:-}"
DSH_BIND_IP="${DSH_BIND_IP:-}"
DSH_PROVIDER="${DSH_PROVIDER:-}"
DSH_MODEL="${DSH_MODEL:-}"
DSH_TELEGRAM_BOT_TOKEN="${DSH_TELEGRAM_BOT_TOKEN:-}"
ALLOWED_USER_IDS="${ALLOWED_USER_IDS:-}"
DSH_UPDATER_TOKEN="${DSH_UPDATER_TOKEN:-}"
DESIGN="${DESIGN:-}"
DSH_DESIGN_PORT="${DSH_DESIGN_PORT:-}"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$CHECK" = 1 ]; then printf '    would run: %s\n' "$*"; else "$@"; fi; }

usage() {
  cat <<'EOF'
Install the DSH setup in one command.

  ./install.sh                        interactive
  ./install.sh --check                print the plan, change nothing
  ./install.sh --mode native --yes    unattended, native (no Docker)
  ./install.sh --config answers.env   answers from a file

Options:
  --mode docker|native   deployment mode (default: ask, else docker)
  --tier sandbox|privileged
                         native only: sandbox (default) or add the docker group
  --dir PATH             deployment directory (default: this checkout / /srv/dsh)
  --design none|docker   optional Penpot design stack (default: ask, else none)
  --ref REF              git ref for the native checkout (default: v<VERSION>)
  --config FILE          read answers from FILE (KEY=VALUE, no shell)
  --yes, -y              accept defaults, never prompt
  --check                print the plan and change nothing
  --uninstall            stop and remove the deployment (keeps data/)
  --purge                with --uninstall: also delete data/, .env and backups/
  -h, --help             this text
EOF
}

# --- answers from a file ---------------------------------------------------
# Strict KEY=VALUE parsing: no sourcing, so a config file cannot execute code.
CONFIG_KEYS="MODE TIER DIR SERVICE_USER DSH_PORT DSH_BIND_IP DSH_PROVIDER DSH_MODEL
DSH_TELEGRAM_BOT_TOKEN ALLOWED_USER_IDS DSH_UPDATER_TOKEN DESIGN DSH_DESIGN_PORT PROVIDER_KEY"
load_config() {
  local file="$1" line key value
  [ -f "$file" ] || die "no config file: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    case " $(echo $CONFIG_KEYS) " in
      *" $key "*) ;;
      *) die "unknown key in $file: $key" ;;
    esac
    printf -v "$key" '%s' "$value"
  done < "$file"
}

ARGS=("$@")
# --config is read first so explicit CLI flags still win over the file.
i=0
while [ $i -lt ${#ARGS[@]} ]; do
  case "${ARGS[$i]}" in
    --config)   CONFIG="${ARGS[$((i + 1))]:-}"; i=$((i + 2)); continue ;;
    --config=*) CONFIG="${ARGS[$i]#*=}" ;;
  esac
  i=$((i + 1))
done
if [ -n "$CONFIG" ]; then load_config "$CONFIG"; fi
set -- "${ARGS[@]}"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)   MODE="${2:?--mode needs a value}"; shift 2 ;;
    --mode=*) MODE="${1#*=}"; shift ;;
    --tier)   TIER="${2:?--tier needs a value}"; shift 2 ;;
    --tier=*) TIER="${1#*=}"; shift ;;
    --design) DESIGN="${2:?--design needs a value}"; shift 2 ;;
    --design=*) DESIGN="${1#*=}"; shift ;;
    --ref)    REF="${2:?--ref needs a value}"; shift 2 ;;
    --ref=*)  REF="${1#*=}"; shift ;;
    --dir)    DIR="${2:?--dir needs a value}"; shift 2 ;;
    --dir=*)  DIR="${1#*=}"; shift ;;
    --config) shift 2 ;;
    --config=*) shift ;;
    --yes|-y) YES=1; shift ;;
    --check)  CHECK=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge)  PURGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done


if [ "$PURGE" = 1 ] && [ "$UNINSTALL" != 1 ]; then
  die "--purge only makes sense with --uninstall"
fi

# --- prompts ---------------------------------------------------------------
ask() {
  local var="$1" prompt="$2" def="${3:-}" current answer
  current="${!var:-}"
  [ -n "$current" ] && def="$current"
  if [ "$YES" = 1 ] || [ "$CHECK" = 1 ] || [ ! -t 0 ]; then
    printf -v "$var" '%s' "$def"
    return 0
  fi
  printf '%s [%s]: ' "$prompt" "$def"
  read -r answer || answer=""
  printf -v "$var" '%s' "${answer:-$def}"
}

ask_secret() {
  local var="$1" prompt="$2" current answer
  current="${!var:-}"
  if [ -n "$current" ] || [ "$YES" = 1 ] || [ "$CHECK" = 1 ] || [ ! -t 0 ]; then
    [ -n "$current" ] || printf -v "$var" '%s' ''
    return 0
  fi
  printf '%s (blank = disabled): ' "$prompt"
  read -r -s answer || answer=""
  printf '\n'
  printf -v "$var" '%s' "$answer"
}

detect_lan_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
      | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
  fi
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | head -n1 || true)"
  printf '%s\n' "${ip:-127.0.0.1}"
}

random_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  elif command -v node >/dev/null 2>&1; then
    node -e 'process.stdout.write(require("node:crypto").randomBytes(24).toString("hex"))'
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

# Re-running must keep what the deployment already answered; only fill blanks.
read_existing_env() {
  local key value
  [ -f "$DIR/.env" ] || return 0
  for key in DSH_PORT DSH_BIND_IP DSH_PROVIDER DSH_MODEL DSH_TELEGRAM_BOT_TOKEN \
             ALLOWED_USER_IDS DSH_UPDATER_TOKEN DESIGN DSH_DESIGN_PORT; do
    value="$(sed -n "s/^${key}=//p" "$DIR/.env" | head -1)"
    if [ -n "${!key:-}" ]; then
      # An exported variable silently winning over the deployed value is how a
      # repair run rewrites a working allowlist by accident.
      if [ -n "$value" ] && [ "${!key}" != "$value" ]; then
        warn "$key is set in the environment and overrides the deployed value in $DIR/.env"
      fi
      continue
    fi
    if [ -n "$value" ]; then printf -v "$key" '%s' "$value"; fi
  done
  return 0
}

# A repair run keeps the mode the deployment chose. Without this, `./install.sh`
# or `./install.sh --yes` on a native host defaults to docker and converts (or
# silently disables) the running install.
if [ -z "$MODE" ]; then
  for candidate in "$SRC_DIR/.env" /srv/dsh/.env; do
    [ -f "$candidate" ] || continue
    MODE="$(sed -n 's/^MODE=//p' "$candidate" | head -1)"
    [ -n "$MODE" ] && break
  done
fi

# --- uninstall -------------------------------------------------------------
# Removing a deployment is a first-class operation: stopping stray containers by
# hand is how a second poller survives. Data is kept unless --purge is passed,
# and the checkout is never deleted — the last line says what to remove.
uninstall_plan() {
  printf '    mode:      %s\n' "$MODE"
  printf '    directory: %s\n' "$DIR"
  case "$MODE" in
    docker) printf '    removes:   the compose stack (dsh, updater and the design stack if present)\n' ;;
    native) printf '    removes:   dsh.service, dsh-updater.service and the /usr/local/bin launchers\n' ;;
  esac
  if [ "$PURGE" = 1 ]; then
    printf '    deletes:   %s/data, %s/.env, %s/backups\n' "$DIR" "$DIR" "$DIR"
  else
    printf '    keeps:     %s/data, %s/.env, %s/backups (pass --purge to delete them)\n' "$DIR" "$DIR" "$DIR"
  fi
}

uninstall_run() {
  if [ "$MODE" = docker ]; then
    if command -v docker >/dev/null 2>&1 && [ -f "$DIR/compose.yaml" ]; then
      log "stopping the compose stack"
      run bash -c "cd '$DIR' && docker compose down --remove-orphans" || warn "compose down failed; check docker compose ps"
      if [ "$PURGE" = 1 ]; then
        log "removing the images built for this deployment"
        docker rmi "dsh-backend:$SETUP_VERSION" dsh-backend:self-previous \
          "dsh-updater:$SETUP_VERSION" >/dev/null 2>&1 || true
      fi
    else
      warn "no compose.yaml in $DIR — nothing to stop"
    fi
  else
    if [ -f /etc/systemd/system/dsh.service ]; then
      log "stopping and disabling the systemd units"
      run systemctl disable --now dsh-updater.service 2>/dev/null || true
      run systemctl disable --now dsh.service 2>/dev/null || true
      run rm -f /etc/systemd/system/dsh.service /etc/systemd/system/dsh-updater.service
      run systemctl daemon-reload
    fi
    local launcher
    for launcher in dsh-entrypoint dsh-supervisor dsh-healthcheck dsh-updater.mjs penpot; do
      [ -L "/usr/local/bin/$launcher" ] && run rm -f "/usr/local/bin/$launcher"
    done
    if [ "$PURGE" = 1 ]; then
      if command -v systemctl >/dev/null 2>&1 && id "$SERVICE_USER" >/dev/null 2>&1; then
        if command -v loginctl >/dev/null 2>&1; then
          run loginctl disable-linger "$SERVICE_USER" 2>/dev/null || true
        fi
      fi
    fi
  fi

  if [ "$PURGE" = 1 ]; then
    log "deleting data, .env and backups in $DIR"
    run rm -rf "$DIR/data" "$DIR/backups"
    run rm -f "$DIR/.env"
  fi

  echo
  log "uninstalled ($MODE mode)"
  if [ "$PURGE" != 1 ]; then
    printf '    kept:    %s/data, %s/.env, %s/backups\n' "$DIR" "$DIR" "$DIR"
  fi
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    printf '    user:    %s still exists (userdel -r %s if it owns nothing else)\n' "$SERVICE_USER" "$SERVICE_USER"
  fi
  printf '    dir:     %s still exists (rm -rf %s to remove the checkout)\n' "$DIR" "$DIR"
}

# --- decide ----------------------------------------------------------------
if [ "$YES" != 1 ] && [ "$CHECK" != 1 ] && [ -t 0 ] && [ -z "$MODE" ]; then
  echo
  echo "Which deployment do you want?"
  echo "  1) docker  — container boundary, no host access for the agent (recommended)"
  echo "  2) native  — systemd on this host, no Docker; the agent can read the host"
  printf 'Mode [1]: '
  read -r mode_answer || mode_answer=""
  case "${mode_answer:-1}" in
    1|docker|Docker) MODE=docker ;;
    2|native|Native) MODE=native ;;
    *) die "unknown mode: $mode_answer" ;;
  esac
fi
[ -n "$MODE" ] || MODE=docker
case "$MODE" in docker|native) ;; *) die "--mode must be docker or native" ;; esac

case "${DESIGN:-}" in
  ""|none|docker) ;;
  *) die "--design must be none or docker" ;;
esac

if [ "$MODE" = native ]; then
  [ -n "$TIER" ] || TIER=sandbox
  case "$TIER" in sandbox|privileged) ;; *) die "--tier must be sandbox or privileged" ;; esac
  [ -n "$DIR" ] || DIR=/srv/dsh
else
  [ -z "$TIER" ] || [ "$TIER" = sandbox ] || die "--tier only applies to native mode"
  [ -n "$DIR" ] || DIR="$SRC_DIR"
fi

read_existing_env

# Defaults apply after the existing .env, so a repair keeps the deployed values.
[ -n "$DSH_PORT" ] || DSH_PORT=4310
[ -n "$DESIGN" ] || DESIGN=none
[ "$DESIGN" = docker ] && { [ -n "$DSH_DESIGN_PORT" ] || DSH_DESIGN_PORT=8090; }
[ -n "$DSH_PROVIDER" ] || DSH_PROVIDER=opencode-go
provider_key_env() {
  case "$1" in
    opencode-go) printf %s OPENCODE_GO_API_KEY ;;
    deepseek-official) printf %s DEEPSEEK_API_KEY ;;
    *) printf %s DSH_PROVIDER_API_KEY ;;
  esac
}

model_default() {
  case "$1" in
    opencode-go) printf %s deepseek-v4.1-flash ;;
    *) printf %s deepseek-v4-flash ;;
  esac
}

if [ "$UNINSTALL" = 1 ]; then
  echo
  log "uninstall plan"
  uninstall_plan
  if [ "$CHECK" = 1 ]; then
    echo
    log "check only — nothing was changed"
    exit 0
  fi
  if [ "$YES" != 1 ]; then
    if [ ! -t 0 ]; then
      die "refusing to uninstall without a terminal — add --yes to confirm"
    fi
    printf 'Type "yes" to continue: '
    read -r answer || answer=""
    [ "$answer" = yes ] || die "cancelled"
  fi
  uninstall_run
  exit 0
fi

if [ "$CHECK" != 1 ]; then
  ask DSH_PORT "Web UI port" 4310
  ask DSH_BIND_IP "Web UI address: your LAN IP (phone/browser access) or 127.0.0.1 (host only)" "$(detect_lan_ip)"
  ask DSH_PROVIDER "Model provider (opencode-go or deepseek-official)" opencode-go
  # the model default follows the provider that was just chosen, not the one
  # the pre-prompt default guessed
  [ -n "$DSH_MODEL" ] || DSH_MODEL="$(model_default "$DSH_PROVIDER")"
  ask DSH_MODEL "Model" "$(model_default "$DSH_PROVIDER")"
  PROVIDER_KEY_ENV="$(provider_key_env "$DSH_PROVIDER")"
  ask_secret PROVIDER_KEY "$PROVIDER_KEY_ENV (leave blank to add later)"
  ask_secret DSH_TELEGRAM_BOT_TOKEN "Telegram bot token"
  if [ -n "$DSH_TELEGRAM_BOT_TOKEN" ]; then
    ask ALLOWED_USER_IDS "Allowed Telegram user ids (comma separated)" ""
  fi
  ask DESIGN "Install the Penpot design stack? (docker/none)" none
  if [ "$DESIGN" = docker ]; then
    ask DSH_DESIGN_PORT "Penpot port" 8090
  fi
  if [ -z "$DSH_UPDATER_TOKEN" ]; then
    DSH_UPDATER_TOKEN="$(random_token)"
    log "generated an updater token (stored in the deployment .env)"
  fi
fi
# Unattended runs never asked, so derive both from the provider that applies.
[ -n "$DSH_PROVIDER" ] || DSH_PROVIDER=opencode-go
[ -n "$DSH_MODEL" ] || DSH_MODEL="$(model_default "$DSH_PROVIDER")"

[ -n "$DSH_BIND_IP" ] || DSH_BIND_IP="$(detect_lan_ip)"

DATA_HOME="$DIR/data/home"
DATA_WORKSPACE="$DIR/data/workspace"
SUPERVISOR_STATE="$DIR/data/supervisor"
UPDATER_URL_NATIVE="http://127.0.0.1:8787"
UPDATER_URL_DOCKER="http://updater:8787"
UPDATER_URL="$UPDATER_URL_NATIVE"
[ "$MODE" = docker ] && UPDATER_URL="$UPDATER_URL_DOCKER"

[ -n "$REF" ] || REF="v$SETUP_VERSION"
[ "$MODE" = native ] && [ "$CHECK" != 1 ] && [ "$(id -u)" != 0 ] \
  && die "native mode installs a systemd service — run with sudo"

# --- plan ------------------------------------------------------------------
echo
log "plan"
printf '    mode:      %s\n' "$MODE"
printf '    directory: %s\n' "$DIR"
printf '    version:   %s (DSH %s)\n' "$SETUP_VERSION" "$DSH_VERSION"
printf '    web:       http://%s:%s/\n' "$DSH_BIND_IP" "$DSH_PORT"
printf '    provider:  %s / %s\n' "$DSH_PROVIDER" "$DSH_MODEL"
printf '    telegram:  %s\n' "$([ -n "$DSH_TELEGRAM_BOT_TOKEN" ] && echo configured || echo disabled)"
if [ "$DESIGN" = docker ]; then
  printf '    design:    Penpot on http://%s:%s/\n' "$DSH_BIND_IP" "$DSH_DESIGN_PORT"
else
  printf '    design:    none (re-run with --design docker to add it later)\n'
fi
if [ "$MODE" = native ]; then
  printf '    tier:      %s\n' "$TIER"
  printf '    user:      %s\n' "$SERVICE_USER"
  printf '    data:      %s\n' "$DATA_HOME"
  printf '    updater:   %s (127.0.0.1 only, root)\n' "$UPDATER_URL"
else
  printf '    data:      %s (bind-mounted at /data)\n' "$DIR/data"
  printf '    updater:   sidecar on the internal ops network\n'
fi

if [ "$DSH_BIND_IP" != "127.0.0.1" ] && [ "$DSH_BIND_IP" != "localhost" ]; then
  echo
  warn "the web UI on http://$DSH_BIND_IP:$DSH_PORT/ is protected only by a sign-in"
  warn "  token printed in the startup log. Anyone who can read that log, or follow the"
  warn "  link, drives this agent and runs tools on this host as ${SERVICE_USER:-dsh}."
  warn "  Keep it on a trusted network, or bind 127.0.0.1 and tunnel with:"
  warn "  ssh -L $DSH_PORT:127.0.0.1:$DSH_PORT <user>@<host>"
fi

if [ "$CHECK" = 1 ]; then
  echo
  log "check only — nothing was changed"
  exit 0
fi

# --- shared: write the deployment .env -------------------------------------
set_env() {
  local key="$1" value="$2" file="$3" tmp
  tmp="$(mktemp)"
  if [ -f "$file" ]; then
    grep -v "^${key}=" "$file" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
}

write_env() {
  local file="$1"
  if [ ! -f "$file" ]; then
    if [ "$MODE" = docker ] && [ -f "$SRC_DIR/.env.example" ]; then
      cp "$SRC_DIR/.env.example" "$file"
    else
      : > "$file"
    fi
  fi
  set_env MODE "$MODE" "$file"
  set_env DSH_PORT "$DSH_PORT" "$file"
  set_env DSH_BIND_IP "$DSH_BIND_IP" "$file"
  set_env DSH_PROVIDER "$DSH_PROVIDER" "$file"
  set_env DSH_MODEL "$DSH_MODEL" "$file"
  if [ -n "${PROVIDER_KEY:-}" ]; then
    set_env "${PROVIDER_KEY_ENV:-$(provider_key_env "$DSH_PROVIDER")}" "$PROVIDER_KEY" "$file"
  fi
  set_env DSH_TELEGRAM_BOT_TOKEN "$DSH_TELEGRAM_BOT_TOKEN" "$file"
  set_env ALLOWED_USER_IDS "$ALLOWED_USER_IDS" "$file"
  set_env DSH_UPDATER_TOKEN "$DSH_UPDATER_TOKEN" "$file"
  set_env DSH_SETUP_VERSION "$SETUP_VERSION" "$file"
  set_env DESIGN "$DESIGN" "$file"
  if [ "$DESIGN" = docker ]; then
    set_env DSH_DESIGN_PORT "$DSH_DESIGN_PORT" "$file"
    set_env DSH_DESIGN_ENABLED 1 "$file"
    set_env PENPOT_ENABLED 1 "$file"
    local comp="$DIR/components.json"
    [ -f "$comp" ] || comp="$SRC_DIR/components.json"
    local plugin_ref=""
    [ -f "$comp" ] && plugin_ref="$(node -e 'process.stdout.write(require(process.argv[1]).components.design.plugin.ref)' "$comp" 2>/dev/null || true)"
    if [ -n "$plugin_ref" ]; then set_env PENPOT_PLUGIN_REF "$plugin_ref" "$file"; fi
    if [ "$MODE" = docker ]; then
      set_env PENPOT_API_URL "http://design-frontend:8080" "$file"
    else
      set_env PENPOT_API_URL "http://$DSH_BIND_IP:$DSH_DESIGN_PORT" "$file"
    fi
  else
    set_env DSH_DESIGN_ENABLED 0 "$file"
    set_env PENPOT_ENABLED 0 "$file"
  fi
  set_env DSH_UPDATER_URL "$UPDATER_URL" "$file"
  chmod 600 "$file"
}

wait_health() {
  local timeout="${1:-180}"
  local deadline=$((SECONDS + timeout)) i
  for ((i = 0; i < timeout; i += 2)); do
    if DSH_PORT="$DSH_PORT" "$SRC_DIR/healthcheck.sh" >/dev/null 2>&1; then return 0; fi
    [ "$SECONDS" -ge "$deadline" ] && break
    sleep 2
  done
  return 1
}

# Optional Penpot stack. It is a separate compose project: its own data, its own
# lifecycle, and it can be absent without touching the runtime.
design_apply() {
  [ "$DESIGN" = docker ] || return 0
  if ! command -v docker >/dev/null 2>&1; then
    warn "the design stack needs Docker — skipped; re-run with --design docker later"
    return 0
  fi
  local dir="$DIR/design" env_file="$DIR/design/.env"
  [ -f "$dir/compose.yaml" ] || { warn "no $dir/compose.yaml — skipping the design stack"; return 0; }

  log "writing $env_file"
  if [ ! -f "$env_file" ]; then
    local template="$dir/.env.example"
    [ -f "$template" ] || template="$SRC_DIR/design/.env.example"
    cp "$template" "$env_file"
    set_env PENPOT_DB_PASSWORD "$(random_token)" "$env_file"
    set_env PENPOT_SECRET_KEY "$(random_token)$(random_token)" "$env_file"
    chmod 600 "$env_file"
  fi
  set_env DSH_BIND_IP "$DSH_BIND_IP" "$env_file"
  set_env DSH_DESIGN_PORT "$DSH_DESIGN_PORT" "$env_file"
  if [ "$MODE" = docker ]; then
    set_env PENPOT_API_URL "http://design-frontend:8080" "$DIR/.env"
  else
    set_env PENPOT_API_URL "http://$DSH_BIND_IP:$DSH_DESIGN_PORT" "$DIR/.env"
  fi
  local token
  token="$(sed -n 's/^PENPOT_ACCESS_TOKEN=//p' "$env_file" | head -1)"
  if [ -n "$token" ]; then set_env PENPOT_ACCESS_TOKEN "$token" "$DIR/.env"; fi
  log "restarting the runtime so the Penpot plugin loads"
  if [ "$MODE" = native ]; then
    run systemctl restart dsh.service
  else
    run docker compose --project-directory "$DIR" -f "$DIR/compose.yaml" restart dsh
  fi

  log "starting Penpot (the first start pulls the images)"
  if ! docker network inspect dsh-design >/dev/null 2>&1; then
    run docker network create dsh-design || warn "could not create the dsh-design network"
  fi
  run docker compose --project-directory "$dir" -f "$dir/compose.yaml" up -d --build

  log "waiting for Penpot on http://$DSH_BIND_IP:$DSH_DESIGN_PORT/"
  local waited=0
  while [ "$waited" -lt 300 ]; do
    if curl -s -o /dev/null -m 4 -w '%{http_code}' "http://$DSH_BIND_IP:$DSH_DESIGN_PORT/" 2>/dev/null | grep -qE '200|302|303|304'; then
      break
    fi
    sleep 5; waited=$((waited + 5))
  done
  if [ "$waited" -ge 300 ]; then
    warn "Penpot did not answer within 5 minutes — inspect: docker compose --project-directory $dir ps"
    return 1
  fi

  warn "create the first account at http://$DSH_BIND_IP:$DSH_DESIGN_PORT/ then Settings -> Access tokens,"
  warn "and put the token in $env_file as PENPOT_ACCESS_TOKEN=... to enable the design tools"
}

# Stop the other deployment mode before this one starts: two runtimes sharing a
# bot token fight over the update queue, and two pollers drop messages.
stop_other_mode() {
  if [ "$MODE" = native ]; then
    # The docker deployment may live anywhere: the default docker dir is the
    # checkout and the default native dir is /srv/dsh, so probing only $DIR
    # left a running stack holding the port and the Telegram poller.
    if command -v docker >/dev/null 2>&1; then
      local candidate
      for candidate in "$DIR" "$SRC_DIR" /srv/dsh /opt/dsh "$HOME/dsh"; do
        [ -f "$candidate/compose.yaml" ] || continue
        if ( cd "$candidate" && docker compose ps -q dsh 2>/dev/null | grep -q . ); then
          log "stopping the docker deployment in $candidate"
          run bash -c "cd '$candidate' && docker compose down --remove-orphans"
        fi
      done
    fi
  else
    if [ -f /etc/systemd/system/dsh.service ]; then
      log "stopping the native deployment"
      run systemctl disable --now dsh-updater.service 2>/dev/null || true
      run systemctl disable --now dsh.service 2>/dev/null || true
    fi
  fi
}

# --- docker mode -----------------------------------------------------------
docker_apply() {
  command -v docker >/dev/null 2>&1 || die "docker not found — install Docker, or use --mode native"
  [ -f "$DIR/compose.yaml" ] || die "no compose.yaml in $DIR — run ./install.sh from the checkout"
  stop_other_mode
  mkdir -p "$DIR/data"
  cd "$DIR"
  log "writing $DIR/.env"
  write_env "$DIR/.env"
  # The data directory must be owned by the invoking user, not by root.
  set_env DSH_UID "${SUDO_UID:-$(id -u)}" "$DIR/.env"
  set_env DSH_GID "${SUDO_GID:-$(id -g)}" "$DIR/.env"
  log "building the image (first build downloads DSH; a few minutes)"
  run docker compose build
  log "starting"
  run docker compose up -d
  log "waiting for health"
  if ! wait_health 300; then
    docker compose logs --tail=40 dsh 2>/dev/null || true
    die "dsh did not become healthy — inspect: docker compose logs dsh"
  fi
  design_apply
}

# --- native mode -----------------------------------------------------------
ensure_user() {
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    log "user $SERVICE_USER already exists"
    return 0
  fi
  log "creating the unprivileged service user $SERVICE_USER"
  run useradd --system --home-dir "$DIR" --shell /bin/bash "$SERVICE_USER"
}

native_units() {
  local env_file="$DIR/.env" unit=/etc/systemd/system/dsh.service
  local node_bin node_dir
  node_bin="$(command -v node || echo /usr/local/bin/node)"
  node_dir="$(dirname "$node_bin")"
  local sandbox_lines=""
  if [ "$TIER" = sandbox ]; then
    sandbox_lines="$(cat <<'EOF'
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
ReadWritePaths=/srv/dsh/data
# NETLINK is not a network service: `ip route`, `hostname -I` and
# getifaddrs() need it to discover the interface the runtime binds.
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
EOF
)"
    # ReadWritePaths must match the configured directory.
    sandbox_lines="${sandbox_lines/\/srv\/dsh\/data/$DIR\/data}"
  else
    sandbox_lines="SupplementaryGroups=docker"
  fi

  log "writing $unit"
  cat > "$unit" <<EOF
[Unit]
Description=DeepSeek Harness runtime (web UI + Telegram connector)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$DATA_WORKSPACE
EnvironmentFile=-$env_file
Environment=HOME=$DATA_HOME
Environment=DSH_HOME=$DATA_HOME
Environment=DSH_WORKSPACE=$DATA_WORKSPACE
Environment=DSH_SUPERVISOR_STATE=$SUPERVISOR_STATE
Environment=DSH_ENTRYPOINT=/usr/local/bin/dsh-entrypoint
Environment=DSH_PERMISSION_MODE=danger-full-access
Environment=PATH=$node_dir:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=TMPDIR=$DIR/data/.cache/tmp
# The addon loader caches .node files in TMPDIR; keep it on an exec-capable
# filesystem and out of /tmp (which some hosts mount noexec).
Environment=NARB_NATIVE_CACHE_DIR=$DIR/data/.cache/native
ExecStart=/usr/local/bin/dsh-entrypoint serve
Restart=on-failure
RestartSec=3
KillMode=mixed
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal
$sandbox_lines

[Install]
WantedBy=multi-user.target
EOF

  log "writing /etc/systemd/system/dsh-updater.service"
  cat > /etc/systemd/system/dsh-updater.service <<EOF
[Unit]
Description=DSH setup updater (loopback only)
After=network-online.target dsh.service
Wants=network-online.target

[Service]
Type=simple
# The updater checks out a release tag and restarts dsh.service; that restart
# is the only reason it is root. The runtime itself stays $SERVICE_USER.
User=root
EnvironmentFile=-$env_file
Environment=HOME=/root
Environment=DSH_REPO_DIR=$DIR
Environment=DSH_DATA_DIR=$DIR/data
Environment=DSH_MODE=native
Environment=DSH_UPDATER_PORT=8787
Environment=DSH_UPDATER_HOST=127.0.0.1
ExecStart=$node_bin /usr/local/bin/dsh-updater.mjs
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  run systemctl daemon-reload
}

link_bins() {
  log "linking the launchers into /usr/local/bin"
  run ln -sf "$DIR/entrypoint.sh" /usr/local/bin/dsh-entrypoint
  run ln -sf "$DIR/supervisor.mjs" /usr/local/bin/dsh-supervisor
  run ln -sf "$DIR/healthcheck.sh" /usr/local/bin/dsh-healthcheck
  run ln -sf "$DIR/updater.mjs" /usr/local/bin/dsh-updater.mjs
  run ln -sf "$DIR/design/penpot.mjs" /usr/local/bin/penpot
}

native_apply() {
  command -v node >/dev/null 2>&1 || die "node not found — install Node >= 22.19 first"
  local node_major
  node_major="$(node -p 'process.versions.node.split(".")[0]')"
  [ "$node_major" -ge 22 ] || die "Node >= 22.19 is required (found $(node --version))"

  stop_other_mode
  ensure_user
  log "creating the data layout under $DIR"
  run mkdir -p "$DATA_HOME" "$DATA_WORKSPACE" "$SUPERVISOR_STATE" "$DIR/data/.cache/tmp" "$DIR/backups"
  run chown -R "$SERVICE_USER:$SERVICE_USER" "$DIR/data"

  if [ ! -d "$DIR/.git" ]; then
    log "initialising the setup checkout in $DIR"
    # In place: the directory already holds data/, and a clone would refuse a
    # non-empty destination. The local origin keeps the tags update.sh needs.
    run mkdir -p "$DIR"
    run git -C "$DIR" init --quiet
    run git -C "$DIR" remote add origin "$SRC_DIR"
    run git -C "$DIR" fetch --quiet --tags origin
  fi
  run git -C "$DIR" checkout --quiet --detach "$REF" || \
    warn "could not check out $REF in $DIR; staying on the current HEAD"

  link_bins

  if ! command -v dsh >/dev/null 2>&1 || \
     [ "$(dsh --version 2>/dev/null | tr -d 'v[:space:]')" != "$DSH_VERSION" ]; then
    log "installing @deepseek-ai/dsh@$DSH_VERSION globally"
    # Same two extras the image installs: pnpm builds the Telegram adapter, and
    # --allow-scripts lets node-pty/koffi/dsh-subprocess-local build, without
    # which the bash tool breaks. Omitting either leaves a half-working install.
    run npm install -g --silent \
      --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs \
      "@deepseek-ai/dsh@$DSH_VERSION" pnpm@11
  elif ! command -v pnpm >/dev/null 2>&1; then
    log "installing pnpm (the Telegram adapter builds with it)"
    run npm install -g --silent pnpm@11
  fi

  # The unit resolves `dsh` through PATH; make sure the npm prefix is on it.
  dsh_path="$(type -P dsh 2>/dev/null || true)"
  if [ -n "$dsh_path" ] && [ "$dsh_path" != /usr/local/bin/dsh ]; then
    log "linking $dsh_path as /usr/local/bin/dsh"
    run ln -sf "$dsh_path" /usr/local/bin/dsh
  fi

  log "writing $DIR/.env"
  write_env "$DIR/.env"
  set_env DSH_UID "$(id -u "$SERVICE_USER")" "$DIR/.env"
  set_env DSH_GID "$(id -g "$SERVICE_USER")" "$DIR/.env"
  run chown root:"$SERVICE_USER" "$DIR/.env"
  run chmod 640 "$DIR/.env"

  native_units

  # A re-run must apply the new .env: `enable --now` leaves a running unit alone.
  if systemctl is-active --quiet dsh.service 2>/dev/null; then
    log "restarting dsh.service to apply the new environment"
    run systemctl enable dsh.service
    run systemctl restart dsh.service
  else
    log "starting dsh.service"
    run systemctl enable --now dsh.service
  fi
  if [ -n "$DSH_UPDATER_TOKEN" ]; then
    log "restarting dsh-updater.service"
    run systemctl enable dsh-updater.service
    run systemctl restart dsh-updater.service
  else
    warn "no updater token — /system update all will degrade to host instructions"
  fi

  log "waiting for health"
  if ! wait_health 180; then
    journalctl -u dsh.service --no-pager -n 40 2>/dev/null || true
    die "dsh did not become healthy — inspect: journalctl -u dsh.service -f"
  fi
  design_apply
}

if [ "$MODE" = docker ]; then docker_apply; else native_apply; fi

echo
log "installed: $SETUP_VERSION ($MODE mode)"
printf '    web:     %s\n' "http://$DSH_BIND_IP:$DSH_PORT/ (send /web in the bot chat for a signed link)"
case "$MODE" in
  docker) printf '    logs:    docker compose logs -f dsh\n' ;;
  native) printf '    logs:    journalctl -u dsh.service -f\n' ;;
esac
if [ -z "$(grep -E '^(OPENCODE_GO_API_KEY|DEEPSEEK_API_KEY)=.+' "$DIR/.env" 2>/dev/null || true)" ]; then
  case "$MODE" in
    native) printf '    key:     none yet — add %s to %s/.env, then systemctl restart dsh\n' "$(provider_key_env "$DSH_PROVIDER")" "$DIR" ;;
    docker) printf '    key:     none yet — add %s to %s/.env, then docker compose up -d dsh\n' "$(provider_key_env "$DSH_PROVIDER")" "$DIR" ;;
  esac
fi
printf '    update:  /system update all (Telegram) or ./update.sh --self (host)\n'
printf '    switch:  ./install.sh --mode %s (stops the other mode; data is not moved, see docs/HOST.md)\n' \
  "$([ "$MODE" = docker ] && echo native || echo docker)"
