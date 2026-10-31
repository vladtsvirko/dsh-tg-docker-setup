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

MODE="" TIER="" DIR="" CONFIG="" REF="" CHECK=0 YES=0
SERVICE_USER="${SERVICE_USER:-dsh}"
DSH_PORT="${DSH_PORT:-}"
DSH_BIND_IP="${DSH_BIND_IP:-}"
DSH_PROVIDER="${DSH_PROVIDER:-}"
DSH_MODEL="${DSH_MODEL:-}"
DSH_TELEGRAM_BOT_TOKEN="${DSH_TELEGRAM_BOT_TOKEN:-}"
ALLOWED_USER_IDS="${ALLOWED_USER_IDS:-}"
DSH_UPDATER_TOKEN="${DSH_UPDATER_TOKEN:-}"

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
  --ref REF              git ref for the native checkout (default: v<VERSION>)
  --config FILE          read answers from FILE (KEY=VALUE, no shell)
  --yes, -y              accept defaults, never prompt
  --check                print the plan and change nothing
  -h, --help             this text
EOF
}

# --- answers from a file ---------------------------------------------------
# Strict KEY=VALUE parsing: no sourcing, so a config file cannot execute code.
CONFIG_KEYS="MODE TIER DIR SERVICE_USER DSH_PORT DSH_BIND_IP DSH_PROVIDER DSH_MODEL
DSH_TELEGRAM_BOT_TOKEN ALLOWED_USER_IDS DSH_UPDATER_TOKEN"
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
    --ref)    REF="${2:?--ref needs a value}"; shift 2 ;;
    --ref=*)  REF="${1#*=}"; shift ;;
    --dir)    DIR="${2:?--dir needs a value}"; shift 2 ;;
    --dir=*)  DIR="${1#*=}"; shift ;;
    --config) shift 2 ;;
    --config=*) shift ;;
    --yes|-y) YES=1; shift ;;
    --check)  CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done


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
             ALLOWED_USER_IDS DSH_UPDATER_TOKEN; do
    [ -n "${!key:-}" ] && continue
    value="$(sed -n "s/^${key}=//p" "$DIR/.env" | head -1)"
    if [ -n "$value" ]; then printf -v "$key" '%s' "$value"; fi
  done
  return 0
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
[ -n "$DSH_PROVIDER" ] || DSH_PROVIDER=opencode-go
if [ -z "$DSH_MODEL" ]; then
  case "$DSH_PROVIDER" in
    opencode-go) DSH_MODEL=deepseek-v4.1-flash ;;
    *)           DSH_MODEL=deepseek-v4-flash ;;
  esac
fi

if [ "$CHECK" != 1 ]; then
  ask DSH_PORT "Web UI port" 4310
  ask DSH_BIND_IP "Address to advertise (LAN IP, or 127.0.0.1 for host-only)" "$(detect_lan_ip)"
  ask DSH_PROVIDER "Model provider" opencode-go
  ask DSH_MODEL "Model" deepseek-v4.1-flash
  ask_secret DSH_TELEGRAM_BOT_TOKEN "Telegram bot token"
  if [ -n "$DSH_TELEGRAM_BOT_TOKEN" ]; then
    ask ALLOWED_USER_IDS "Allowed Telegram user ids (comma separated)" ""
  fi
  if [ -z "$DSH_UPDATER_TOKEN" ]; then
    DSH_UPDATER_TOKEN="$(random_token)"
    log "generated an updater token (stored in the deployment .env)"
  fi
fi
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
if [ "$MODE" = native ]; then
  printf '    tier:      %s\n' "$TIER"
  printf '    user:      %s\n' "$SERVICE_USER"
  printf '    data:      %s\n' "$DATA_HOME"
  printf '    updater:   %s (127.0.0.1 only, root)\n' "$UPDATER_URL"
else
  printf '    data:      %s (bind-mounted at /data)\n' "$DIR/data"
  printf '    updater:   sidecar on the internal ops network\n'
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
  set_env DSH_TELEGRAM_BOT_TOKEN "$DSH_TELEGRAM_BOT_TOKEN" "$file"
  set_env ALLOWED_USER_IDS "$ALLOWED_USER_IDS" "$file"
  set_env DSH_UPDATER_TOKEN "$DSH_UPDATER_TOKEN" "$file"
  set_env DSH_SETUP_VERSION "$SETUP_VERSION" "$file"
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

# Stop the other deployment mode before this one starts: two runtimes sharing a
# bot token fight over the update queue, and two pollers drop messages.
stop_other_mode() {
  if [ "$MODE" = native ]; then
    if command -v docker >/dev/null 2>&1 && [ -f "$DIR/compose.yaml" ]; then
      if ( cd "$DIR" && docker compose ps -q dsh 2>/dev/null | grep -q . ); then
        log "stopping the docker deployment in $DIR"
        run bash -c "cd '$DIR' && docker compose down --remove-orphans"
      fi
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
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
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
    run npm install -g --silent "@deepseek-ai/dsh@$DSH_VERSION"
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

  log "starting dsh.service"
  run systemctl enable --now dsh.service
  if [ -n "$DSH_UPDATER_TOKEN" ]; then
    log "starting dsh-updater.service"
    run systemctl enable --now dsh-updater.service
  else
    warn "no updater token — /system update all will degrade to host instructions"
  fi

  log "waiting for health"
  if ! wait_health 180; then
    journalctl -u dsh.service --no-pager -n 40 2>/dev/null || true
    die "dsh did not become healthy — inspect: journalctl -u dsh.service -f"
  fi
}

if [ "$MODE" = docker ]; then docker_apply; else native_apply; fi

echo
log "installed: $SETUP_VERSION ($MODE mode)"
printf '    web:     %s\n' "http://$DSH_BIND_IP:$DSH_PORT/"
case "$MODE" in
  docker) printf '    logs:    docker compose logs -f dsh\n' ;;
  native) printf '    logs:    journalctl -u dsh.service -f\n' ;;
esac
if [ "$MODE" = native ] && [ -z "$(grep -E '^(OPENCODE_GO_API_KEY|DEEPSEEK_API_KEY)=.+' "$DIR/.env" 2>/dev/null || true)" ]; then
  printf '    key:     add your provider key to %s/.env, then systemctl restart dsh\n' "$DIR"
fi
printf '    update:  /system update all (Telegram) or ./update.sh --self (host)\n'
printf '    switch:  ./install.sh --mode %s (migrates the data and stops the other mode)\n' \
  "$([ "$MODE" = docker ] && echo native || echo docker)"
