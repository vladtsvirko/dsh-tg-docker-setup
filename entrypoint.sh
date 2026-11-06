#!/usr/bin/env bash
# First-boot setup + launch for the DeepSeek Harness runtime.
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

DSH_HOME="${DSH_HOME:-/srv/dsh/data/home}"
DSH_WORKSPACE="${DSH_WORKSPACE:-/srv/dsh/data/workspace}"
DSH_PORT="${DSH_PORT:-4310}"
SETUP_VERSION="${DSH_SETUP_VERSION:-0.0.0}"
# The checkout this script belongs to. The entrypoint is symlinked into
# /usr/local/bin, so resolve the link before taking its directory: the shipped
# assets (skills/) sit beside the real file, not beside the symlink.
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SETUP_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"

# plugins.json is the checkout's recommended pin: what a fresh install or a
# repair resolves. It is not a ceiling — a newer compatible version installed
# from the bot (or by hand) stays installed across reboots, and a setup upgrade
# only forces a reinstall when the installed version is below `minimum`.
catalog_value() {
  local key="$1" field="$2"
  [ -f "$SETUP_DIR/plugins.json" ] || return 1
  node -e '
    try {
      const catalog = require(process.argv[1])
      const value = catalog.plugins?.[process.argv[2]]?.[process.argv[3]]
      if (value !== undefined && value !== null) process.stdout.write(String(value))
    } catch {}
  ' "$SETUP_DIR/plugins.json" "$key" "$field" 2>/dev/null
}

# The catalog moved from GitHub `ref` to an install `spec`; read both so an
# older checkout still boots with a newer entrypoint.
catalog_spec() {
  local key="$1"
  catalog_value "$key" spec || catalog_value "$key" ref
}

# The package name a spec installs. npm: `name@1.2.3`, git:
# `github:owner/repo#v1.2.3`. Scoped npm names keep their scope.
spec_package() {
  case "${1:-}" in
    github:*) printf '%s' "$1" | sed -e 's|^github:||' -e 's|#.*$||' -e 's|\.git$||' -e 's|/$||' | awk -F/ '{ print $NF }' ;;
    *@[0-9]*) printf '%s' "${1%@*}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# A targeted update from the bot names the exact spec for this one run. It wins
# over both the .env override and the checkout pin; the next boot falls back to
# whatever the profile has installed.
PLUGIN_TARGET_REF="${DSH_PLUGIN_TARGET_REF:-}"
PLUGIN_REF="${DSH_TELEGRAM_PLUGIN:-}"
PLUGIN_REF_FROM_ENV=0
[ -n "$PLUGIN_REF" ] && PLUGIN_REF_FROM_ENV=1
if [ -z "$PLUGIN_REF" ]; then
  PLUGIN_REF="$(catalog_spec dsh-telegram-connector || true)"
fi
# Last-resort pin for a checkout whose catalog is missing (a partial copy). Not
# `main`: a missing catalog must not silently make the bot float.
if [ -z "$PLUGIN_REF" ]; then
  PLUGIN_REF="github:vladtsvirko/dsh-telegram-connector#v0.13.0"
fi
PLUGIN_MIN="$(catalog_value dsh-telegram-connector minimum || true)"
PLUGIN_FALLBACK="$(catalog_value dsh-telegram-connector fallback || true)"
# Which package this ref installs. Derived from the spec unless stated, because
# the patch row id and the install check both key off the package name.
PLUGIN_PKG="${DSH_TELEGRAM_PACKAGE:-}"
if [ -z "$PLUGIN_PKG" ]; then
  PLUGIN_PKG="$(spec_package "$PLUGIN_REF")"
fi
ALLOWED_USER_IDS="${ALLOWED_USER_IDS:-}"
# The one account that may run /system update|restart|rollback and /plugin.
ADMIN_USER_ID="${DSH_ADMIN_USER_ID:-}"
BOT_TOKEN="${DSH_TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_ENABLED="${DSH_TELEGRAM_ENABLED:-auto}"
PENPOT_ENABLED="${PENPOT_ENABLED:-0}"
PENPOT_REF="${PENPOT_PLUGIN_REF:-}"
PENPOT_REF_FROM_ENV=0
[ -n "$PENPOT_REF" ] && PENPOT_REF_FROM_ENV=1
if [ -z "$PENPOT_REF" ]; then
  PENPOT_REF="$(catalog_spec dsh-penpot-plugin || true)"
fi
PENPOT_MIN="$(catalog_value dsh-penpot-plugin minimum || true)"
PENPOT_FALLBACK="$(catalog_value dsh-penpot-plugin fallback || true)"
PENPOT_PKG="dsh-penpot-plugin"

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
# loopback-only and needs a bearer token; a fresh one per start is
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
export DSH_SUPERVISOR_STATE="${DSH_SUPERVISOR_STATE:-/srv/dsh/data/supervisor}"

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
  # A first run on a fresh checkout can land here with a data directory that a
  # root install left root-owned. Fail with the fix rather than looping on
  # "mkdir: cannot create directory".
  if ! mkdir -p "$DSH_HOME" "$DSH_WORKSPACE" 2>/dev/null ||
     ! : > "$DSH_HOME/.write-test" 2>/dev/null; then
    warn "$DSH_HOME is not writable by uid $(id -u):$(id -g)"
    warn "the data directory is probably owned by root — fix it on the host:"
    warn "  sudo chown -R $(id -u):$(id -g) ${DSH_HOME%/home}/"
    warn "  sudo systemctl restart dsh.service"
    exit 1
  fi
  rm -f "$DSH_HOME/.write-test"
  # the addon cache must live on an exec-capable filesystem, not /tmp
  mkdir -p "${NARB_NATIVE_CACHE_DIR:-${DSH_HOME%/home}/.cache/native}" 2>/dev/null || true
  chmod 0750 "$DSH_HOME" "$DSH_WORKSPACE" 2>/dev/null || true
}

# --- one runtime per data directory ---------------------------------------
# Two runtimes over the same data directory (two services from different
# checkouts, or a hand-started runtime beside the service) corrupt the session
# store, fight over the Telegram long poll, and each holds the other's session
# write handles. That last one is what the user sees: the web UI of one runtime
# shows a stale workspace list while the other's Telegram says "this session is
# held by another client", and restarting one does not clear it — the other
# process still holds the lock.
#
# The kernel owns the lock, so a crashed runtime never leaves it behind. The
# marker beside it is informational: it names the holder for the refusal message
# and for ./install.sh --doctor.
DATA_ROOT="$(cd "$DSH_HOME/.." 2>/dev/null && pwd -P || printf '%s' "$DSH_HOME/..")"
export DSH_DATA_ROOT="$DATA_ROOT"
INSTANCE_LOCK="$DATA_ROOT/.runtime.lock"
INSTANCE_FILE="$DATA_ROOT/.runtime.json"

instance_holder() {
  [ -f "$INSTANCE_FILE" ] || return 0
  local mode pid since
  mode="$(sed -n 's/.*"mode":[[:space:]]*"\([^"]*\)".*/\1/p' "$INSTANCE_FILE" | head -1)"
  pid="$(sed -n 's/.*"pid":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$INSTANCE_FILE" | head -1)"
  since="$(sed -n 's/.*"startedAt":[[:space:]]*"\([^"]*\)".*/\1/p' "$INSTANCE_FILE" | head -1)"
  printf '%s mode, pid %s, since %s' "${mode:-?}" "${pid:-?}" "${since:-?}"
}

acquire_instance() {
  local wait_s="${DSH_INSTANCE_WAIT_SECONDS:-20}" waited=0 holder
  if ! command -v flock >/dev/null 2>&1; then
    warn "flock is unavailable — the one-runtime-per-data-directory guard is off"
    return 0
  fi
  mkdir -p "$DATA_ROOT" 2>/dev/null || true
  exec 9>>"$INSTANCE_LOCK" || { warn "cannot open $INSTANCE_LOCK — continuing without the instance guard"; return 0; }
  while ! flock -n 9; do
    if [ "$waited" = 0 ]; then
      holder="$(instance_holder)"
      warn "another dsh runtime already uses $DATA_ROOT${holder:+ — its marker says $holder}"
      warn "two runtimes on one data directory corrupt sessions and hold each other's write handles;"
      warn "stop the other one first:  sudo systemctl stop dsh.service"
    fi
    [ "$waited" -ge "$wait_s" ] && return 1
    sleep 1
    waited=$((waited + 1))
  done
  # The id, not the pid, is what identifies this runtime to its children: the
  # entrypoint execs into the supervisor and the supervisor spawns dsh as a
  # child, so the plugin process has a different pid but the same environment.
  INSTANCE_ID="${SETUP_VERSION}-$$-$(date +%s)"
  export DSH_INSTANCE_ID="$INSTANCE_ID"
  # Every value goes through %s so a missing one can never produce invalid JSON:
  # the plugin parses this file and must never crash on it.
  printf '{"id":"%s","mode":"%s","pid":%s,"version":"%s","startedAt":"%s"}\n' \
    "$INSTANCE_ID" "native" "$$" "$SETUP_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$INSTANCE_FILE.tmp" 2>/dev/null &&
    mv "$INSTANCE_FILE.tmp" "$INSTANCE_FILE" 2>/dev/null || true
  return 0
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
    local ids="" admin_line=""
    if [ -n "$ALLOWED_USER_IDS" ]; then
      ids="$(printf '%s' "$ALLOWED_USER_IDS" | tr ',' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//; s/ /, /g')"
    fi
    # Omitted rather than defaulted: the connector then treats the control
    # chat's owner as admin, which is what an upgraded deployment expects.
    if [ -n "$ADMIN_USER_ID" ]; then
      admin_line="    adminUserId: $ADMIN_USER_ID"
    fi
    # config keys shared by both connectors; no cwd, so an adapter that does not
    # declare one still validates
    cat > "$block" <<BLOCK
# >>> dsh-telegram (managed by entrypoint.sh — edits here are overwritten)
- id: $PLUGIN_PKG
  config:
    botToken: !!js process.env.DSH_TELEGRAM_BOT_TOKEN ?? ''
    allowedUserIds: [$ids]
$admin_line
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

# The spec the profile currently records for a package, if any. `reset-plugin`
# uses it so a reinstall keeps the version the bot moved to instead of
# downgrading to the checkout's recommendation. pnpm stores an npm dependency as
# a bare version (`0.13.1`), so turn that back into the spec the caller installs.
profile_dependency() {
  [ -f "$PROFILE_DIR/package.json" ] || return 1
  node -e '
    try {
      const name = process.argv[2]
      const spec = require(process.argv[1]).dependencies?.[name]
      if (typeof spec !== "string" || spec.length === 0) process.exit(0)
      process.stdout.write(/^[0-9]+\.[0-9]+\.[0-9]+/.test(spec) ? name + "@" + spec : spec)
    } catch {}
  ' "$PROFILE_DIR/package.json" "$1" 2>/dev/null
}

# The version part of a spec: `github:o/r#v1.2.3` or `name@1.2.3`, or empty.
ref_version() {
  case "${1:-}" in
    *'#'v*) printf '%s' "${1##*#v}" ;;
    *@[0-9]*) printf '%s' "${1##*@}" ;;
    *) return 1 ;;
  esac
}

# True when $1 (a package version) is at least $2. Prereleases sort below their
# stable release, which matters because DSH tags carry an rc suffix.
version_gte() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  node -e '
    const parse = (text) => {
      const match = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(text)
      return match === null ? undefined : [Number(match[1]), Number(match[2]), Number(match[3]), match[4] === undefined ? [] : match[4].split(".")]
    }
    const one = parse(process.argv[1])
    const two = parse(process.argv[2])
    if (one === undefined || two === undefined) process.exit(2)
    for (let index = 0; index < 3; index += 1) {
      if (one[index] !== two[index]) process.exit(one[index] > two[index] ? 0 : 1)
    }
    const left = one[3]
    const right = two[3]
    if (left.length === 0 && right.length === 0) process.exit(0)
    if (left.length === 0) process.exit(0)
    if (right.length === 0) process.exit(1)
    for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
      const a = left[index]
      const b = right[index]
      if (a === undefined) process.exit(1)
      if (b === undefined) process.exit(0)
      if (a === b) continue
      const an = /^\d+$/.test(a)
      const bn = /^\d+$/.test(b)
      if (an && bn) process.exit(Number(a) > Number(b) ? 0 : 1)
      if (an) process.exit(1)
      if (bn) process.exit(0)
      process.exit(a > b ? 0 : 1)
    }
    process.exit(0)
  ' "$1" "$2" 2>/dev/null
}

# Install one exact spec, handling the two pnpm gates that a git install can
# hit. Registry installs skip both. Returns 0 on success.
install_spec() {
  local pkg="$1" spec="$2" log="$3" attempts="$4" compat="$5" out attempt key ws
  for attempt in $(seq 1 "$attempts"); do
    if dsh plugin --profile web add "$spec" >"$log" 2>&1; then
      return 0
    fi
    out="$(cat "$log")"

    # gate 1 — pnpm blocks a git package's prepare script
    if grep -q 'ERR_PNPM_GIT_DEP_PREPARE_NOT_ALLOWED\|Failed to prepare git-hosted' <<<"$out"; then
      key="$(grep -o "$pkg@https:[^ ]*: true" <<<"$out" | head -n1)"
      ws="$PROFILE_DIR/pnpm-workspace.yaml"
      if [ -n "$key" ] && ! grep -qF "$key" "$ws" 2>/dev/null; then
        log "allowing $pkg's build script"
        if grep -q '^allowBuilds:' "$ws" 2>/dev/null; then
          awk -v entry="  $key" '/^allowBuilds:/ { print; print entry; next } { print }' "$ws" > "$ws.new"
          mv "$ws.new" "$ws"
        else
          printf '\nallowBuilds:\n  %s\n' "$key" >> "$ws"
        fi
        continue
      fi
    fi

    # gate 2 — the connector declares peers for a different DSH line
    if [ "$compat" = 1 ] && grep -q 'is incompatible with dsh' <<<"$out"; then
      local refused refused_version
      refused="$(grep -o 'allow-version [^ ]*' <<<"$out" | head -n1 | cut -d' ' -f2)"
      refused_version="$(grep -o -- '--dsh-version [^ ]*' <<<"$out" | head -n1 | cut -d' ' -f2)"
      if [ -n "$refused" ] && [ -n "$refused_version" ]; then
        warn "granting a version exemption for $refused on dsh $refused_version (unverified combination)"
        dsh plugin --profile web allow-version "$refused" --dsh-version "$refused_version" --accept-risk || true
        continue
      fi
    fi
    break
  done
  return 1
}

# pnpm may save a registry range (`^0.13.0`); the profile should record the
# exact spec so a later reset reinstalls what the bot chose, not a newer patch.
# An npm dependency value is a bare version: pnpm parses `name@version` there as
# `name@name@version` and refuses the whole install. A git spec keeps its form.
pin_dependency() {
  node -e '
    const fs = require("node:fs")
    const [file, name, spec] = process.argv.slice(1)
    const value = spec.startsWith(name + "@") ? spec.slice(name.length + 1) : spec
    const pkg = JSON.parse(fs.readFileSync(file, "utf8"))
    pkg.dependencies = { ...(pkg.dependencies ?? {}), [name]: value }
    fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + "\n")
  ' "$PROFILE_DIR/package.json" "$1" "$2" 2>/dev/null || true
}

# Releases up to 0.13.1 wrote the full `name@version` spec into package.json.
# pnpm cannot resolve that value, and the failure is fatal for every install in
# the profile — not just the package named there — so a deployment updated from
# one of those releases cannot install a plugin until it is repaired.
normalize_profile_specs() {
  [ -f "$PROFILE_DIR/package.json" ] || return 0
  node -e '
    const fs = require("node:fs")
    const file = process.argv[1]
    const pkg = JSON.parse(fs.readFileSync(file, "utf8"))
    let changed = false
    for (const [name, spec] of Object.entries(pkg.dependencies ?? {})) {
      if (typeof spec !== "string" || !spec.startsWith(name + "@")) continue
      const version = spec.slice(name.length + 1)
      if (!/^[0-9]/.test(version)) continue
      pkg.dependencies[name] = version
      changed = true
    }
    if (changed) fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + "\n")
  ' "$PROFILE_DIR/package.json" 2>/dev/null || true
}

install_plugin() {
  # Check the installed copy, not the manifest entry: `reset-plugin` keeps the
  # dependency but wipes node_modules, and that must re-trigger the install.
  #
  # A newer compatible connector installed from the bot must survive a reboot,
  # so the checkout pin is a floor, not a ceiling. Only a missing package, a
  # package below `minimum`, or an explicit target triggers a reinstall.
  local stamp="$PROFILE_DIR/.telegram-plugin-ref" target desired installed_version min override_version fallback candidates candidate
  target="$PLUGIN_TARGET_REF"
  desired="${target:-$PLUGIN_REF}"
  min="$PLUGIN_MIN"
  [ "$PLUGIN_PKG" = "dsh-telegram-connector" ] || min=""
  fallback="$PLUGIN_FALLBACK"
  [ "$PLUGIN_REF_FROM_ENV" = 1 ] && fallback=""
  # An old .env override must not keep a deployment below the release floor.
  if [ -z "$target" ] && [ -n "$min" ] && [ "$PLUGIN_REF_FROM_ENV" = 1 ]; then
    override_version="$(ref_version "$PLUGIN_REF" || true)"
    if ! version_gte "$override_version" "$min"; then
      desired="$(catalog_spec dsh-telegram-connector || true)"
      warn "DSH_TELEGRAM_PLUGIN is below the required $min; using $desired"
      PLUGIN_REF="$desired"
    fi
  fi
  if [ -f "$PROFILE_DIR/node_modules/$PLUGIN_PKG/package.json" ] && [ -z "$target" ]; then
    installed_version="$(node -p "require('$PROFILE_DIR/node_modules/$PLUGIN_PKG/package.json').version" 2>/dev/null || true)"
    if [ -z "$min" ] || version_gte "$installed_version" "$min"; then
      return 0
    fi
    log "connector $installed_version is older than the required $min; reinstalling"
  fi
  if [ -f "$PROFILE_DIR/node_modules/$PLUGIN_PKG/package.json" ]; then
    log "reinstalling the Telegram adapter"
    dsh plugin --profile web remove "$PLUGIN_PKG" >/dev/null 2>&1 || true
    rm -rf "$PROFILE_DIR/node_modules/$PLUGIN_PKG"
  fi
  command -v pnpm >/dev/null 2>&1 ||
    warn "pnpm is not on PATH — the adapter install will fail; install pnpm"

  candidates=("$desired")
  if [ -z "$target" ] && [ -n "$fallback" ] && [ "$fallback" != "$desired" ]; then
    candidates+=("$fallback")
  fi
  for candidate in "${candidates[@]}"; do
    [ -n "$candidate" ] || continue
    log "installing the Telegram adapter from $candidate (needs network)"
    if install_spec "$PLUGIN_PKG" "$candidate" /tmp/plugin-install.log 4 1; then
      pin_dependency "$PLUGIN_PKG" "$candidate"
      log "adapter installed"
      printf '%s\n' "$candidate" > "$stamp"
      return 0
    fi
    warn "install failed for $candidate — see /tmp/plugin-install.log"
  done
  warn "adapter install failed — the web UI still works"
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
  # The manifest lives inside the deployment; the unit points DSH_GIT_SECRETS
  # at it. /run/secrets remains the fallback for a manual run.
  local base="${DSH_GIT_SECRETS:-/run/secrets/git}"
  local manifest="$base/profiles.json"
  [ -f "$manifest" ] || return 0
  if node /usr/local/bin/dsh-git-credentials.mjs; then
    return 0
  fi
  warn "git credentials failed — fix $manifest or see docs/GIT.md"
}

install_penpot() {
  # Same shape as the Telegram adapter: the checkout pin installs a missing
  # plugin and enforces a minimum, but never downgrades a newer version the bot
  # installed through the plugin manager.
  local stamp="$PROFILE_DIR/.penpot-plugin-ref" installed_version desired override_version fallback candidates candidate
  [ -n "$PENPOT_REF" ] || { warn "PENPOT_PLUGIN_REF is empty — design tools stay off"; return 1; }
  desired="$PENPOT_REF"
  fallback="$PENPOT_FALLBACK"
  [ "$PENPOT_REF_FROM_ENV" = 1 ] && fallback=""
  # A legacy pin below the release floor is upgraded, not obeyed forever.
  if [ -n "$PENPOT_MIN" ] && [ "$PENPOT_REF_FROM_ENV" = 1 ]; then
    override_version="$(ref_version "$PENPOT_REF" || true)"
    if ! version_gte "$override_version" "$PENPOT_MIN"; then
      desired="$(catalog_spec dsh-penpot-plugin || true)"
      warn "PENPOT_PLUGIN_REF is below the required $PENPOT_MIN; using $desired"
    fi
  fi
  if [ -f "$PROFILE_DIR/node_modules/$PENPOT_PKG/package.json" ]; then
    installed_version="$(node -p "require('$PROFILE_DIR/node_modules/$PENPOT_PKG/package.json').version" 2>/dev/null || true)"
    if [ -z "$PENPOT_MIN" ] || version_gte "$installed_version" "$PENPOT_MIN"; then
      return 0
    fi
    log "Penpot plugin $installed_version is older than the required $PENPOT_MIN; reinstalling"
    dsh plugin --profile web remove "$PENPOT_PKG" >/dev/null 2>&1 || true
    rm -rf "$PROFILE_DIR/node_modules/$PENPOT_PKG"
  fi
  command -v pnpm >/dev/null 2>&1 ||
    warn "pnpm is not on PATH — the plugin install will fail; install pnpm"

  candidates=("$desired")
  if [ -n "$fallback" ] && [ "$fallback" != "$desired" ]; then candidates+=("$fallback"); fi
  for candidate in "${candidates[@]}"; do
    [ -n "$candidate" ] || continue
    log "installing the Penpot plugin from $candidate (needs network)"
    if install_spec "$PENPOT_PKG" "$candidate" /tmp/penpot-install.log 3 0; then
      pin_dependency "$PENPOT_PKG" "$candidate"
      log "Penpot plugin installed"
      printf '%s\n' "$candidate" > "$stamp"
      return 0
    fi
    warn "install failed for $candidate — see /tmp/penpot-install.log"
  done
  warn "Penpot plugin install failed — the design tools stay off"
  return 1
}

# Managed row for the plugin. Off keeps the package (a cheap re-enable) but
# disables the row; when the package was never installed there is no row at all.
set_penpot_patch() {
  local mode="$1" block
  block="$(mktemp)"
  if [ "$mode" = on ]; then
    cat > "$block" <<BLOCK
# >>> dsh-penpot (managed by entrypoint.sh — edits here are overwritten)
- id: dsh-penpot
  config:
    apiUrl: !!js process.env.PENPOT_API_URL ?? ''
    token: !!js process.env.PENPOT_ACCESS_TOKEN ?? ''
# <<< dsh-penpot
BLOCK
  elif [ "$mode" = off ]; then
    cat > "$block" <<BLOCK
# >>> dsh-penpot (managed by entrypoint.sh — edits here are overwritten)
- id: dsh-penpot
  disabled: true
# <<< dsh-penpot
BLOCK
  fi
  apply_managed_block dsh-penpot "$block"
  rm -f "$block"
}

# Skills shipped in this checkout land in the user skill root, where the harness
# discovers them for every workspace and session. The copy is managed by the
# setup: a release refreshes it, so change the repository copy, not the
# installed one. Only skills with a SKILL.md are copied; anything else under
# $DSH_HOME/skills stays untouched.
install_skills() {
  local src="$SETUP_DIR/skills" dst="$DSH_HOME/skills" dir name
  [ -d "$src" ] || return 0
  for dir in "$src"/*/; do
    [ -f "$dir/SKILL.md" ] || continue
    name="$(basename "$dir")"
    if [ -d "$dst/$name" ] && diff -rq "$dir" "$dst/$name" >/dev/null 2>&1; then
      continue
    fi
    mkdir -p "$dst"
    rm -rf "$dst/$name"
    if cp -R "$dir" "$dst/$name"; then
      log "skill installed: $name"
    else
      warn "could not install the '$name' skill from $src"
    fi
  done
}

prepare() {
  prepare_dirs
  setup_git_credentials
  init_profile
  normalize_profile_specs
  set_provider_patch
  install_skills

  log "model route: $PROVIDER/$MODEL"
  if [ -n "$KEY_ENV" ] && [ -z "$(printenv "$KEY_ENV" 2>/dev/null || true)" ]; then
    warn "$KEY_ENV is empty — the runtime will boot, but model calls will fail"
  fi

  local mode installed=0
  mode="$(telegram_mode)"
  [ -f "$PROFILE_DIR/node_modules/$PLUGIN_PKG/package.json" ] && installed=1

  if [ "$mode" = on ]; then
    if ! install_plugin; then
      # A repair may leave the web UI up; a targeted update must fail loudly so
      # the supervisor restores the stable profile instead of booting without a
      # bot and waiting for the trial deadline.
      if [ -n "$PLUGIN_TARGET_REF" ]; then
        warn "targeted connector update failed — refusing to boot without it"
        exit 1
      fi
    fi
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

  if [ "$PENPOT_ENABLED" = 1 ]; then
    if install_penpot; then
      set_penpot_patch on
      log "design: Penpot tools enabled"
    else
      set_penpot_patch off
    fi
  elif [ -f "$PROFILE_DIR/node_modules/$PENPOT_PKG/package.json" ]; then
    set_penpot_patch off
    log "design: Penpot tools disabled (package kept for a cheap re-enable)"
  else
    set_penpot_patch none
  fi
}

# The runtime binds the configured address directly. 127.0.0.1 is a real
# host-only bind (dsh rejects wildcards), so a loopback install must not be
# translated to a LAN address here.
web_bind_ip() {
  printf '%s\n' "${DSH_BIND_IP:-127.0.0.1}"
}

serve() {
  local bind args public authority
  # The guard comes first: preparing the profile while another runtime serves it
  # would rewrite the patch under a live process for no benefit.
  if ! acquire_instance; then
    warn "not starting: another runtime owns $DATA_ROOT — stop it and start this one again"
    # Exit cleanly. systemd would otherwise restart the unit forever, and the
    # container's policy ignores the code anyway; the wait above bounds both.
    exit 0
  fi
  bind="$(web_bind_ip)"

  # The advertised root is what the browser is told to dial — for the UI's API
  # and WebSocket, not just the printed link. A loopback bind needs it set
  # explicitly, or the runtime advertises an address the browser cannot use.
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
    # The profile is the source of truth for what is installed. Capture both
    # specs before `dsh plugin remove` rewrites package.json, so a repair of a
    # deployment the bot updated does not silently downgrade it.
    if [ -z "$PLUGIN_TARGET_REF" ] && [ "$PLUGIN_REF_FROM_ENV" = 0 ]; then
      current_connector="$(profile_dependency "$PLUGIN_PKG" || true)"
      if [ -n "$current_connector" ]; then
        PLUGIN_TARGET_REF="$current_connector"
        export DSH_PLUGIN_TARGET_REF="$current_connector"
        log "reinstalling the connector at its installed spec: $current_connector"
      fi
    fi
    if [ "$PENPOT_REF_FROM_ENV" = 0 ]; then
      current_penpot="$(profile_dependency "$PENPOT_PKG" || true)"
      if [ -n "$current_penpot" ]; then PENPOT_REF="$current_penpot"; fi
    fi
    # Switching connectors changes PLUGIN_PKG; remove the package the previous
    # install recorded, or the old poller stays installed beside the new one.
    old_ref="$(cat "$PROFILE_DIR/.telegram-plugin-ref" 2>/dev/null || true)"
    old_pkg=""
    case "$old_ref" in
      github:*) old_pkg="$(printf '%s' "$old_ref" | sed -e 's|^github:||' -e 's|#.*$||' -e 's|\.git$||' -e 's|/$||')" ;;
      *) [ -n "$old_ref" ] && old_pkg="$(basename "$old_ref")" ;;
    esac
    old_pkg="${old_pkg##*/}"
    if [ -n "$old_pkg" ] && [ "$old_pkg" != "$PLUGIN_PKG" ]; then
      log "removing the previous connector package: $old_pkg"
      dsh plugin --profile web remove "$old_pkg" >/dev/null 2>&1 || true
    fi
    log "resetting the profile plugin layer"
    dsh plugin --profile web remove "$PLUGIN_PKG" >/dev/null 2>&1 || true
    rm -rf "$PROFILE_DIR/node_modules" "$PROFILE_DIR/pnpm-lock.yaml" "$PROFILE_DIR/compatibility.json"
    prepare
    ;;
  *) exec "$@" ;;
esac
