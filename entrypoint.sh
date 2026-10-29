#!/usr/bin/env bash
# First-boot setup + launch for the DeepSeek Harness container.
#
#   serve         (default)  prepare the profile, then run the web UI (+ Telegram if configured)
#   init                     prepare the profile and exit
#   reset-plugin             drop + re-resolve the profile's plugin layer
#   <cmd...>                 anything else is exec'd as-is
#
# Two things are optional and env-driven:
#   * the model route  — DSH_PROVIDER / DSH_MODEL / DSH_PROVIDER_API_KEY_ENV
#   * Telegram         — DSH_TELEGRAM_BOT_TOKEN, on exactly when the token is set
set -euo pipefail

DSH_HOME="${DSH_HOME:-/data/home}"
DSH_WORKSPACE="${DSH_WORKSPACE:-/data/workspace}"
DSH_PORT="${DSH_PORT:-4310}"
SETUP_VERSION="${DSH_SETUP_VERSION:-0.0.0}"
PLUGIN_REF="${DSH_TELEGRAM_PLUGIN:-github:vladtsvirko/dsh-telegram-connector#v${SETUP_VERSION}}"
# The setup release owns the connector version: if the configured ref points at
# this connector, force the matching tag instead of an older user override.
case "$PLUGIN_REF" in
  github:vladtsvirko/dsh-telegram-connector*) PLUGIN_REF="github:vladtsvirko/dsh-telegram-connector#v${SETUP_VERSION}" ;;
esac
# Which package this ref installs. Derived from the ref unless stated, because the
# patch row id and the install check both key off the package name.
PLUGIN_PKG="${DSH_TELEGRAM_PACKAGE:-}"
if [ -z "$PLUGIN_PKG" ]; then
  case "$PLUGIN_REF" in
    github:*) PLUGIN_PKG="$(printf '%s' "$PLUGIN_REF" | sed -e 's|^github:||' -e 's|#.*$||' -e 's|\.git$||' -e 's|/$||')" ;;
    *)        PLUGIN_PKG="$(basename "$PLUGIN_REF")" ;;
  esac
  PLUGIN_PKG="${PLUGIN_PKG##*/}"
fi
ALLOWED_USER_IDS="${ALLOWED_USER_IDS:-}"
BOT_TOKEN="${DSH_TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_ENABLED="${DSH_TELEGRAM_ENABLED:-auto}"

# --- model route ----------------------------------------------------------
# opencode-go is the default here because it is what this deployment uses; the
# DeepSeek platform route is one env change away.
PROVIDER="${DSH_PROVIDER:-opencode-go}"
MODEL="${DSH_MODEL:-}"
if [ -z "$MODEL" ]; then
  case "$PROVIDER" in
    opencode-go) MODEL="deepseek-v4.1-flash" ;;
    *)           MODEL="deepseek-v4-flash" ;;
  esac
fi
KEY_ENV="${DSH_PROVIDER_API_KEY_ENV:-}"
if [ -z "$KEY_ENV" ]; then
  case "$PROVIDER" in
    opencode-go)       KEY_ENV="OPENCODE_GO_API_KEY" ;;
    deepseek-official) KEY_ENV="DEEPSEEK_API_KEY" ;;
    *)                 KEY_ENV="" ;;
  esac
fi

PROFILE_DIR="$DSH_HOME/profiles/web"
PATCH="$PROFILE_DIR/cordis.patch.yml"

# --- supervisor -----------------------------------------------------------
# The supervisor owns restarts and the rollback snapshot. Its control socket is
# loopback-only and needs a bearer token; a fresh one per container start is
# enough, because the connector reads it from this same environment.
SUPERVISOR_TOKEN="${DSH_SUPERVISOR_TOKEN:-}"
if [ -z "$SUPERVISOR_TOKEN" ]; then
  SUPERVISOR_TOKEN="$(head -c 48 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 40 || true)"
  # never hand the supervisor an empty token: it refuses to start without one
  [ -n "$SUPERVISOR_TOKEN" ] || SUPERVISOR_TOKEN="$(date +%s%N 2>/dev/null || date +%s)-$$"
fi
export DSH_SUPERVISOR_TOKEN="$SUPERVISOR_TOKEN"
export DSH_SUPERVISOR_URL="${DSH_SUPERVISOR_URL:-http://127.0.0.1:8469}"
export DSH_SUPERVISOR_PORT="${DSH_SUPERVISOR_PORT:-8469}"
export DSH_SUPERVISOR_PROFILE="$PROFILE_DIR"
export DSH_SUPERVISOR_STATE="${DSH_SUPERVISOR_STATE:-/data/supervisor}"

log()  { printf '  [dsh] %s\n' "$*"; }
warn() { printf '  [dsh] WARNING: %s\n' "$*" >&2; }

# on | off — `auto` enables the adapter exactly when a token is present.
telegram_mode() {
  case "$TELEGRAM_ENABLED" in
    1|true|yes|on)  echo on ;;
    0|false|no|off) echo off ;;
    auto|'')
      if [ -n "$BOT_TOKEN" ]; then echo on; else echo off; fi
      ;;
    *)
      warn "unknown DSH_TELEGRAM_ENABLED=$TELEGRAM_ENABLED (expected on|off|auto); using auto"
      if [ -n "$BOT_TOKEN" ]; then echo on; else echo off; fi
      ;;
  esac
}

prepare_dirs() {
  # Docker creates a missing bind-mount source as root:root, so a first run on a
  # fresh checkout lands here with an unwritable /data. Fail with the fix rather
  # than looping on "mkdir: cannot create directory".
  if ! mkdir -p "$DSH_HOME" "$DSH_WORKSPACE" 2>/dev/null ||
     ! : > "$DSH_HOME/.write-test" 2>/dev/null; then
    warn "/data is not writable by uid $(id -u):$(id -g)"
    warn "the bind-mounted ./data directory is probably owned by root — fix it on the host:"
    warn "  sudo chown -R $(id -u):$(id -g) ./data"
    warn "  docker compose restart dsh"
    exit 1
  fi
  rm -f "$DSH_HOME/.write-test"
  # native addon cache must live on an exec-capable filesystem, not /tmp
  mkdir -p "${NARB_NATIVE_CACHE_DIR:-/data/.cache/native}" 2>/dev/null || true
  chmod 0750 "$DSH_HOME" "$DSH_WORKSPACE" 2>/dev/null || true
}

init_profile() {
  [ -f "$PROFILE_DIR/package.json" ] && return 0
  log "materialising the 'web' profile in $DSH_HOME"
  dsh --profile web --help >/dev/null
}

# Replace one marker-delimited block in the profile patch, leaving every other
# entry (user edits included) alone. An empty block file removes the block.
apply_managed_block() {
  local key="$1" block="${2:-}" tmp
  tmp="$(mktemp)"

  awk -v b="# >>> $key" -v e="# <<< $key" '
    index($0, b) == 1 { skip = 1; next }
    index($0, e) == 1 { skip = 0; next }
    !skip { print }
  ' "$PATCH" > "$tmp"

  # migrate unmarked telegram blocks written by older versions of this script
  if [ "$key" = dsh-telegram ]; then
    awk 'BEGIN{ s=0 }
         /^- id: dsh-telegram[[:space:]]*$/ { s=1; next }
         s && /^- / { s=0 }
         !s { print }' "$tmp" > "$tmp.legacy"
    mv "$tmp.legacy" "$tmp"
  fi

  if [ -n "$block" ] && [ -s "$block" ]; then
    if grep -qx '\[\]' "$tmp"; then
      awk -v f="$block" '
        !done && $0 == "[]" { while ((getline line < f) > 0) print line; done=1; next }
        { print }
      ' "$tmp" > "$tmp.out"
      mv "$tmp.out" "$tmp"
    else
      cat "$block" >> "$tmp"
    fi
  fi

  # an array of only comments parses as null; keep a valid empty array
  if ! grep -qv '^[[:space:]]*\(#\|$\)' "$tmp"; then
    echo '[]' >> "$tmp"
  fi

  mv "$tmp" "$PATCH"
}

# Non-DeepSeek routes need their provider registered on the pi-ai plugin, plus an
# explicit default model for new sessions.
set_provider_patch() {
  local block
  block="$(mktemp)"
  if [ "$PROVIDER" != "deepseek-official" ] && [ -n "$KEY_ENV" ]; then
    cat > "$block" <<BLOCK
# >>> dsh-provider (managed by entrypoint.sh — edits here are overwritten)
- id: llm-pi-ai
  config:
    providers:
      $PROVIDER:
        apiKeyEnv: $KEY_ENV
- id: agent-default-model
  config:
    provider: '$PROVIDER'
    model: '$MODEL'
# <<< dsh-provider
BLOCK
  fi
  apply_managed_block dsh-provider "$block"
  rm -f "$block"
}

# mode=on writes the adapter config; mode=off disables the row so the plugin
# stays installed but never mounts or polls.
set_telegram_patch() {
  local mode="$1" block
  block="$(mktemp)"
  if [ "$mode" = none ]; then
    : # leave the block empty: removes any stale managed entry
  elif [ "$mode" = on ]; then
    local ids=""
    if [ -n "$ALLOWED_USER_IDS" ]; then
      ids="$(printf '%s' "$ALLOWED_USER_IDS" | tr ',' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//; s/ /, /g')"
    fi
    # config keys shared by both connectors; no cwd, so an adapter that does not
    # declare one still validates
    cat > "$block" <<BLOCK
# >>> dsh-telegram (managed by entrypoint.sh — edits here are overwritten)
- id: $PLUGIN_PKG
  config:
    botToken: !!js process.env.DSH_TELEGRAM_BOT_TOKEN ?? ''
    allowedUserIds: [$ids]
    provider: '$PROVIDER'
    model: '$MODEL'
# <<< dsh-telegram
BLOCK
    [ -n "$ids" ] || warn "ALLOWED_USER_IDS is empty — the bot will reject every user"
  else
    cat > "$block" <<BLOCK
# >>> dsh-telegram (managed by entrypoint.sh — edits here are overwritten)
- id: $PLUGIN_PKG
  disabled: true
# <<< dsh-telegram
BLOCK
  fi
  apply_managed_block dsh-telegram "$block"
  rm -f "$block"
}

install_plugin() {
  # Check the installed copy, not the manifest entry: `reset-plugin` keeps the
  # dependency but wipes node_modules, and that must re-trigger the install.
  # The ref stamp makes a setup release that pins a new connector reinstall it.
  local stamp="$PROFILE_DIR/.telegram-plugin-ref"
  if [ -f "$PROFILE_DIR/node_modules/$PLUGIN_PKG/package.json" ] &&
     [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$PLUGIN_REF" ]; then
    return 0
  fi
  if [ -f "$PROFILE_DIR/node_modules/$PLUGIN_PKG/package.json" ] && [ -f "$stamp" ]; then
    log "Telegram adapter ref changed; reinstalling it"
    dsh plugin --profile web remove "$PLUGIN_PKG" >/dev/null 2>&1 || true
    rm -rf "$PROFILE_DIR/node_modules/$PLUGIN_PKG"
  fi
  command -v pnpm >/dev/null 2>&1 ||
    warn "pnpm is not on PATH — the adapter's build step will fail (see Dockerfile)"
  log "installing the Telegram adapter (needs network)"
  local out attempt
  for attempt in 1 2 3 4; do
    if dsh plugin --profile web add "$PLUGIN_REF" >/tmp/plugin-install.log 2>&1; then
      log "adapter installed"
      printf '%s\n' "$PLUGIN_REF" > "$stamp"
      return 0
    fi
    out="$(cat /tmp/plugin-install.log)"

    # gate 1 — pnpm blocks the git package's prepare script
    if grep -q 'ERR_PNPM_GIT_DEP_PREPARE_NOT_ALLOWED\|Failed to prepare git-hosted' <<<"$out"; then
      local key
      key="$(grep -o "$PLUGIN_PKG@https:[^ ]*: true" <<<"$out" | head -n1)"
      # grant this exact key whether or not an allowBuilds section already
      # exists: switching connectors leaves the old package's entry behind, and
      # a guard on the section header would then never add the new one
      local ws="$PROFILE_DIR/pnpm-workspace.yaml"
      if [ -n "$key" ] && ! grep -qF "$key" "$ws" 2>/dev/null; then
        log "allowing the adapter's build script"
        if grep -q '^allowBuilds:' "$ws" 2>/dev/null; then
          awk -v entry="  $key" '/^allowBuilds:/ { print; print entry; next } { print }' "$ws" > "$ws.new"
          mv "$ws.new" "$ws"
        else
          printf '\nallowBuilds:\n  %s\n' "$key" >> "$ws"
        fi
        continue
      fi
    fi

    # gate 2 — the adapter declares peers for dsh 0.1.x
    if grep -q 'is incompatible with dsh' <<<"$out"; then
      local pkg ver
      pkg="$(grep -o 'allow-version [^ ]*' <<<"$out" | head -n1 | cut -d' ' -f2)"
      ver="$(grep -o -- '--dsh-version [^ ]*' <<<"$out" | head -n1 | cut -d' ' -f2)"
      if [ -n "$pkg" ] && [ -n "$ver" ]; then
        warn "granting a version exemption for $pkg on dsh $ver (unverified combination)"
        dsh plugin --profile web allow-version "$pkg" --dsh-version "$ver" --accept-risk || true
        continue
      fi
    fi
    break
  done
  warn "adapter install failed — see /tmp/plugin-install.log; the web UI still works"
  warn "runbook: README.md → Troubleshooting"
  return 1
}

# dsh mounts the adapter only through an *exact-version* exemption, and neither a
# plugin upgrade nor a dsh upgrade inherits one. Without this, every image
# rebuild would silently drop the bot while the web UI kept working.
ensure_compat() {
  local pkg_json="$PROFILE_DIR/node_modules/$PLUGIN_PKG/package.json"
  [ -f "$pkg_json" ] || return 0

  local plugin_version runtime compat
  plugin_version="$(node -p "require('$pkg_json').version" 2>/dev/null || true)"
  [ -n "$plugin_version" ] || return 0
  runtime="$(dsh --version 2>/dev/null | tr -d '[:space:]')"
  [ -n "$runtime" ] || return 0
  compat="$PROFILE_DIR/compatibility.json"

  if [ -f "$compat" ] && node -e '
        const c = require(process.argv[1]);
        const list = c[process.argv[2]];
        process.exit(Array.isArray(list) && list.includes(process.argv[3]) ? 0 : 1);
      ' "$compat" "$PLUGIN_PKG@$plugin_version" "$runtime" 2>/dev/null; then
    return 0
  fi

  # Only grant when the runtime genuinely does not satisfy the plugin's own DSH
  # peer ranges — otherwise every boot would leave a pointless exemption behind.
  if NODE_PATH="$(npm root -g)/@deepseek-ai/dsh/node_modules" node -e '
        const semver = require("semver");
        const pkg = require(process.argv[1]);
        const runtime = process.argv[2];
        const ranges = Object.entries(pkg.peerDependencies || {})
          .filter(([name]) => name.startsWith("@deepseek-ai/dsh-"));
        const unmet = ranges.filter(([, range]) => !semver.satisfies(runtime, range, { includePrerelease: true }));
        process.exit(unmet.length === 0 ? 0 : 1);
      ' "$pkg_json" "$runtime" 2>/dev/null; then
    return 0
  fi

  warn "no exact-version exemption for $PLUGIN_PKG@$plugin_version on dsh $runtime — granting it"
  dsh plugin --profile web allow-version "$PLUGIN_PKG@$plugin_version" \
    --dsh-version "$runtime" --accept-risk ||
    warn "could not grant the exemption; the Telegram adapter will not load"
}

setup_git_credentials() {
  local manifest=/run/secrets/git/profiles.json
  [ -f "$manifest" ] || return 0
  if node /usr/local/bin/dsh-git-credentials.mjs; then
    return 0
  fi
  warn "git credentials failed — fix $manifest or see docs/GIT.md"
}

prepare() {
  prepare_dirs
  setup_git_credentials
  init_profile
  set_provider_patch

  log "model route: $PROVIDER/$MODEL"
  if [ -n "$KEY_ENV" ] && [ -z "$(printenv "$KEY_ENV" 2>/dev/null || true)" ]; then
    warn "$KEY_ENV is empty — the runtime will boot, but model calls will fail"
  fi

  local mode installed=0
  mode="$(telegram_mode)"
  [ -f "$PROFILE_DIR/node_modules/$PLUGIN_PKG/package.json" ] && installed=1

  if [ "$mode" = on ]; then
    install_plugin || true
    if [ -f "$PROFILE_DIR/node_modules/$PLUGIN_PKG/package.json" ]; then
      ensure_compat
      set_telegram_patch on
      log "telegram: enabled"
    else
      set_telegram_patch off
    fi
  else
    if [ "$installed" = 1 ]; then
      log "telegram: disabled (token empty or DSH_TELEGRAM_ENABLED=off) — adapter stays installed but off"
      set_telegram_patch off
    else
      log "telegram: not configured — web UI only (set DSH_TELEGRAM_BOT_TOKEN to enable)"
      set_telegram_patch none
    fi
  fi
}

# The address Docker publishes the port to: the container's default-network
# interface. `hostname -I` lists every network in arbitrary order, so a
# recreate can put the internal `ops` address first and the web UI then binds
# where the published port never forwards. The default route uniquely names
# the right interface (`ops` is internal and has no default route).
web_bind_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
      | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
  fi
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | head -n1)"
  printf '%s\n' "${ip:-127.0.0.1}"
}

serve() {
  local bind args public authority
  # dsh rejects wildcard binds, so bind the container's own (non-loopback)
  # address; that is what the published port forwards to.
  bind="$(web_bind_ip)"

  # The advertised root is what the browser is told to dial — for the UI's API and
  # WebSocket, not just the printed link. Left to itself the container advertises
  # its own address (172.x), which the browser cannot reach through a published
  # port, so the UI loads and then reconnects forever. DSH_BIND_IP is the host
  # side of that mapping (compose passes it through via env_file).
  public="${DSH_PUBLIC_URL:-}"
  if [ -z "$public" ] && [ -n "${DSH_BIND_IP:-}" ] && [ "${DSH_BIND_IP}" != "127.0.0.1" ]; then
    public="http://${DSH_BIND_IP}:${DSH_PORT}/"
  fi

  args=(--profile web --host "$bind" --port "$DSH_PORT" --no-open)
  if [ -n "$public" ]; then
    authority="$(printf '%s' "$public" | sed -e 's|^[A-Za-z]*://||' -e 's|/.*$||')"
    args+=(--public-url "$public" --trusted-host "$authority")
    log "advertising $public (authority $authority trusted)"
  fi

  log "listening on $bind:$DSH_PORT"
  exec node /usr/local/bin/dsh-supervisor -- dsh "${args[@]}"
}

case "${1:-serve}" in
  serve) prepare; serve ;;
  init)  prepare ;;
  reset-plugin)
    prepare_dirs
    log "resetting the profile plugin layer"
    dsh plugin --profile web remove "$PLUGIN_PKG" >/dev/null 2>&1 || true
    rm -rf "$PROFILE_DIR/node_modules" "$PROFILE_DIR/pnpm-lock.yaml" "$PROFILE_DIR/compatibility.json"
    prepare
    ;;
  *) exec "$@" ;;
esac
