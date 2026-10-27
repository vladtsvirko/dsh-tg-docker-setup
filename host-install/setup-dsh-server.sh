#!/usr/bin/env bash
#
# Bootstrap a DeepSeek Harness "backend" on an Ubuntu 22.04 home server.
#
# One runtime, two clients:
#   - the web UI       -> http://<bind-host>:<port>   (your Mac, over the LAN)
#   - the Telegram bot -> dsh-telegram plugin mounted in the same profile
#
# Both talk to the same agent runtime, the same tools and the same session store.
#
# Usage:
#   sudo -E ./setup-dsh-server.sh             # install / re-run (idempotent)
#   sudo -E ./setup-dsh-server.sh --check     # print actions, change nothing
#
# Common overrides (environment):
#   DSH_PROVIDER=deepseek-official DSH_MODEL=deepseek-v4-flash
#   ALLOWED_USER_IDS=123456789                 # comma separated Telegram user ids
#   TELEGRAM_BOT_TOKEN=123:abc                 # or leave empty and edit .env after
#   DSH_PKG=@deepseek-ai/dsh@0.1.0-rc.8        # pin for strict plugin compatibility
#
set -euo pipefail

# ----------------------------------------------------------------------------
# configuration
# ----------------------------------------------------------------------------
DSH_SERVICE_USER="${DSH_SERVICE_USER:-dsh}"
DSH_ROOT="${DSH_ROOT:-/srv/dsh}"
DSH_HOME_DIR="${DSH_HOME_DIR:-$DSH_ROOT/home}"
DSH_WORKSPACE="${DSH_WORKSPACE:-$DSH_ROOT/workspace}"
DSH_PORT="${DSH_PORT:-4310}"
DSH_PROVIDER="${DSH_PROVIDER:-deepseek-official}"
DSH_MODEL="${DSH_MODEL:-deepseek-v4-flash}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
ALLOWED_USER_IDS="${ALLOWED_USER_IDS:-}"
DSH_PKG="${DSH_PKG:-@deepseek-ai/dsh@0.2.1-rc.2}"
TELEGRAM_PLUGIN="${TELEGRAM_PLUGIN:-github:ben7am1n/dsh-telegram}"
ALLOW_INCOMPATIBLE="${ALLOW_INCOMPATIBLE:-1}"   # pass --accept-risk on the version gate
NODE_MIN_MINOR=19                               # 22.19 is dsh-telegram's documented floor
CHECK_ONLY=0

detect_bind_host() {
  local ip
  ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  [ -n "$ip" ] && { echo "$ip"; return; }
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "$ip" ] && { echo "$ip"; return; }
  echo "127.0.0.1"
}
DSH_BIND_HOST="${DSH_BIND_HOST:-$(detect_bind_host)}"

[ "${1:-}" = "--check" ] && CHECK_ONLY=1

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$CHECK_ONLY" = 1 ]; then echo "    would run: $*"; else "$@"; fi; }

# run a command as the service user, inside the harness environment
as_dsh() {
  sudo -u "$DSH_SERVICE_USER" env HOME="$DSH_USER_HOME" DSH_HOME="$DSH_HOME_DIR" "$@"
}

# ----------------------------------------------------------------------------
# preflight
# ----------------------------------------------------------------------------
[ "$(id -u)" = 0 ] || die "run with sudo (needs apt, useradd, systemctl)"
[ -r /etc/os-release ] || die "no /etc/os-release — is this Ubuntu?"
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || warn "not Ubuntu ($ID) — continuing anyway"
log "target: Ubuntu ${VERSION_ID:-?} | bind $DSH_BIND_HOST:$DSH_PORT | DSH_HOME $DSH_HOME_DIR"

for bin in curl git; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    log "installing $bin"
    run apt-get update -qq
    run apt-get install -y -qq "$bin"
  fi
done

# ----------------------------------------------------------------------------
# 1. Node.js >= 22.19  and  pnpm
# ----------------------------------------------------------------------------
node_ok=0
if command -v node >/dev/null 2>&1; then
  cur="$(node -v | sed 's/^v//')"
  major="${cur%%.*}"; rest="${cur#*.}"; minor="${rest%%.*}"
  if [ "$major" -gt 22 ] || { [ "$major" -eq 22 ] && [ "$minor" -ge "$NODE_MIN_MINOR" ]; }; then node_ok=1; fi
  log "found node v$cur (usable: $node_ok)"
fi
if [ "$node_ok" = 0 ]; then
  log "installing Node.js 24 from NodeSource"
  run bash -c 'curl -fsSL https://deb.nodesource.com/setup_24.x | bash -'
  run apt-get install -y -qq nodejs
  [ "$CHECK_ONLY" = 1 ] || node -v | grep -qE '^v(2[2-9]|[3-9][0-9])\.' || die "node install failed"
fi
# pnpm must be on PATH: the telegram plugin builds itself through a `prepare`
# script that shells out to `pnpm install`.
if ! command -v pnpm >/dev/null 2>&1; then
  log "installing pnpm (needed to build the Telegram plugin)"
  run npm install -g pnpm
fi

# ----------------------------------------------------------------------------
# 2. dsh CLI
# ----------------------------------------------------------------------------
log "installing $DSH_PKG"
# npm >= 11 skips dependency install scripts by default; dsh needs node-pty's
# prebuild, koffi's binding and the subprocess spawn helper, or the bash tool
# breaks at runtime.
run npm install -g \
  --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs \
  "$DSH_PKG"
if [ "$CHECK_ONLY" = 0 ]; then
  command -v dsh >/dev/null || die "dsh not on PATH after install"
  log "dsh version: $(dsh --version 2>/dev/null || echo unknown)"
fi
DSH_BIN="$(command -v dsh || echo /usr/bin/dsh)"

# ----------------------------------------------------------------------------
# 3. service user + directories
# ----------------------------------------------------------------------------
if ! id -u "$DSH_SERVICE_USER" >/dev/null 2>&1; then
  log "creating service user $DSH_SERVICE_USER"
  run useradd --create-home --shell /bin/bash "$DSH_SERVICE_USER"
fi
for d in "$DSH_HOME_DIR" "$DSH_WORKSPACE"; do
  run install -d -o "$DSH_SERVICE_USER" -g "$DSH_SERVICE_USER" -m 750 "$d"
done
DSH_USER_HOME="$(getent passwd "$DSH_SERVICE_USER" | cut -d: -f6)"

# ----------------------------------------------------------------------------
# 4. materialise the web profile
# ----------------------------------------------------------------------------
PROFILE_DIR="$DSH_HOME_DIR/profiles/web"
PATCH="$PROFILE_DIR/cordis.patch.yml"
if [ "$CHECK_ONLY" = 0 ]; then
  log "materialising the web profile"
  as_dsh "$DSH_BIN" --profile web --help >/dev/null
  [ -f "$PATCH" ] || die "profile patch not created at $PATCH"
fi

# ----------------------------------------------------------------------------
# 5. install the Telegram adapter (two gates: pnpm build allowlist, version gate)
# ----------------------------------------------------------------------------
log "installing $TELEGRAM_PLUGIN into profile 'web'"
if [ "$CHECK_ONLY" = 0 ]; then
  TMPOUT="$(mktemp)"
  ok=0
  for attempt in 1 2 3 4; do
    if as_dsh "$DSH_BIN" plugin --profile web add "$TELEGRAM_PLUGIN" >"$TMPOUT" 2>&1; then
      ok=1; break
    fi

    # gate 1 — pnpm blocks the git package's prepare script
    if grep -q 'ERR_PNPM_GIT_DEP_PREPARE_NOT_ALLOWED\|Failed to prepare git-hosted' "$TMPOUT"; then
      key="$(grep -o 'dsh-telegram@https:[^ ]*: true' "$TMPOUT" | head -n1)"
      if [ -n "$key" ] && ! grep -q '^allowBuilds:' "$PROFILE_DIR/pnpm-workspace.yaml" 2>/dev/null; then
        log "allowing the plugin build script (attempt $attempt)"
        printf '\nallowBuilds:\n  %s\n' "$key" >> "$PROFILE_DIR/pnpm-workspace.yaml"
        chown "$DSH_SERVICE_USER:$DSH_SERVICE_USER" "$PROFILE_DIR/pnpm-workspace.yaml"
        continue
      fi
    fi

    # gate 2 — the plugin declares peer ranges for an older dsh
    if grep -q 'is incompatible with dsh' "$TMPOUT"; then
      pkg="$(grep -o 'allow-version [^ ]*' "$TMPOUT" | head -n1 | cut -d' ' -f2)"
      ver="$(grep -o -- '--dsh-version [^ ]*' "$TMPOUT" | head -n1 | cut -d' ' -f2)"
      if [ -n "$pkg" ] && [ -n "$ver" ]; then
        if [ "$ALLOW_INCOMPATIBLE" = 1 ]; then
          warn "plugin $pkg was built against an older dsh — granting a version exemption for $ver"
          warn "re-test after every dsh upgrade; this is a real compatibility risk"
          as_dsh "$DSH_BIN" plugin --profile web allow-version "$pkg" --dsh-version "$ver" --accept-risk || true
          continue
        fi
        warn "plugin $pkg rejected as incompatible with dsh $ver"
        warn "set ALLOW_INCOMPATIBLE=1, or pin DSH_PKG=@deepseek-ai/dsh@0.1.0-rc.8"
      fi
    fi
    break
  done
  if [ "$ok" != 1 ]; then
    warn "plugin installation did not complete — see $PROFILE_DIR/.plugin-manager/logs/"
    warn "runbook: host-install/README.md"
  else
    log "plugin installed"
  fi
  rm -f "$TMPOUT"
fi

# ----------------------------------------------------------------------------
# 6. pin the adapter's config (the profile patch layer wins over bundle defaults)
# ----------------------------------------------------------------------------
ids=""
[ -n "$ALLOWED_USER_IDS" ] && ids="$(printf '%s' "$ALLOWED_USER_IDS" | tr ',' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//; s/ /, /g')"

BLOCK="- id: dsh-telegram
  name: dsh-telegram
  config:
    allowedUserIds: [$ids]
    provider: '$DSH_PROVIDER'
    model: '$DSH_MODEL'
    cwd: '$DSH_WORKSPACE'"

if [ "$CHECK_ONLY" = 1 ]; then
  echo "    would pin dsh-telegram: allowedUserIds=[$ids] provider=$DSH_PROVIDER model=$DSH_MODEL cwd=$DSH_WORKSPACE"
elif grep -q '^  name: dsh-telegram' "$PATCH" 2>/dev/null; then
  log "dsh-telegram config already pinned — edit $PATCH to change it"
else
  log "pinning dsh-telegram config in $PATCH"
  if grep -qx '\[\]' "$PATCH" 2>/dev/null; then
    printf '%s\n' "$BLOCK" > "$PROFILE_DIR/.patch.new"
    awk -v newfile="$PROFILE_DIR/.patch.new" '
      !done && $0 == "[]" { while ((getline line < newfile) > 0) print line; done=1; next }
      { print }
    ' "$PATCH" > "$PROFILE_DIR/.patch.out"
    mv "$PROFILE_DIR/.patch.out" "$PATCH"
    rm -f "$PROFILE_DIR/.patch.new"
  else
    printf '%s\n' "$BLOCK" >> "$PATCH"
  fi
  chown "$DSH_SERVICE_USER:$DSH_SERVICE_USER" "$PATCH"
  [ -n "$ids" ] || warn "allowedUserIds is empty — the bot will reject every user until you set it"
fi

# ----------------------------------------------------------------------------
# 7. env file (secrets, mode 600)
# ----------------------------------------------------------------------------
ENV_FILE="$DSH_HOME_DIR/.env"
if [ "$CHECK_ONLY" = 0 ]; then
  if [ -f "$ENV_FILE" ]; then
    warn "$ENV_FILE exists — leaving it alone (add your API key there by hand)"
  else
    log "writing $ENV_FILE"
    umask 077
    cat > "$ENV_FILE" <<ENV
# DeepSeek Harness runtime secrets — keep mode 600, never commit.
# Provider route: $DSH_PROVIDER
DEEPSEEK_API_KEY=
# OPENCODE_GO_API_KEY=

# Telegram adapter (read by the plugin as its botToken default)
DSH_TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
ENV
    chown "$DSH_SERVICE_USER:$DSH_SERVICE_USER" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
  fi
fi

# ----------------------------------------------------------------------------
# 8. systemd unit
# ----------------------------------------------------------------------------
UNIT=/etc/systemd/system/dsh.service
log "writing $UNIT"
if [ "$CHECK_ONLY" = 0 ]; then
  cat > "$UNIT" <<UNITEOF
[Unit]
Description=DeepSeek Harness runtime (web UI + Telegram adapter)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$DSH_SERVICE_USER
WorkingDirectory=$DSH_WORKSPACE
Environment=HOME=$DSH_USER_HOME
Environment=DSH_HOME=$DSH_HOME_DIR
EnvironmentFile=-$ENV_FILE
ExecStart=$DSH_BIN --profile web --host $DSH_BIND_HOST --port $DSH_PORT --no-open
Restart=on-failure
RestartSec=3
# the runtime owns subprocesses (bash tool); tear them down with it
KillMode=mixed
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNITEOF
  systemctl daemon-reload
  systemctl enable --now dsh.service
  sleep 2
  systemctl --no-pager --lines=10 status dsh.service || true
fi

# ----------------------------------------------------------------------------
# summary
# ----------------------------------------------------------------------------
cat <<SUMMARY

$( [ "$CHECK_ONLY" = 1 ] && echo "DRY RUN complete — nothing changed." || echo "Done." )

  Web UI     http://$DSH_BIND_HOST:$DSH_PORT
  DSH_HOME   $DSH_HOME_DIR
  Workspace  $DSH_WORKSPACE
  Logs       journalctl -u dsh -f
  Restart    sudo systemctl restart dsh

Remaining steps:
  1. put your API key in $ENV_FILE, then: sudo systemctl restart dsh
  2. set your Telegram user id (ALLOWED_USER_IDS) and re-run, or edit
     allowedUserIds in $PATCH
  3. message the bot: /start
SUMMARY
