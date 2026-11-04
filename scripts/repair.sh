#!/usr/bin/env bash
#
# Check — and with --fix, repair — a deployed DSH setup.
#
# This is the one implementation of "is this deployment healthy, and what is
# still wrong with it". install.sh runs it at the end of every install/repair,
# update.sh runs it after every successful self-update, and both expose it as
# `--doctor`. Keeping it out of both scripts is what makes an install, a repair
# and an update answer the same questions in the same words.
#
# What it checks, and why each one has bitten a real deployment:
#
#   env-file          a key written twice, a CRLF line or a world-readable file
#                     is invisible until systemd and the runtime disagree.
#   provider-key      an empty or malformed key boots fine and fails every model
#                     call with an error that names the variable, not the cause.
#   credential-store  the runtime's .credentials.yaml outranks the process
#                     environment, so a key saved once in the web UI silently
#                     defeats every later .env edit ("the repair did nothing").
#   patch             the entrypoint manages blocks in cordis.patch.yml by
#                     marker; an interrupted write can leave two copies, and the
#                     profile then mounts the same plugin twice.
#   instance          two runtimes on one data directory corrupt the session
#                     store and hold each other's session write handles, which
#                     surfaces as "this session is held by another client".
#   version           .env records the setup release that wrote it; a stale one
#                     makes an update believe it is somewhere it is not.
#   service           the unit is the deployment, not the checkout.
#   web               the port the operator will open, actually listening.
#   data-owner        a root-owned data directory after a `sudo ./install.sh`
#                     run is the classic "cannot write to /data" first boot.
#
# Every line is `ok|warn|fix|fail  <check>  <sentence>`, so the output is stable
# enough to assert on and readable enough to paste into a chat.
#
# Usage:
#   scripts/repair.sh [--dir PATH] [--fix] [--quiet]
#
# Exit: 0 when nothing is wrong (warnings included), 1 when a failure remains.
#
# Covered by repair.test.mjs.
set -uo pipefail

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
say()  { printf '%-5s %-16s %s\n' "$1" "$2" "$3"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

MODE=""
DIR=""
FIX=0
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    # Accepted for compatibility with a 0.7.x caller; the deployment has one
    # shape now, so the value is ignored.
    --mode) shift 2 ;;
    --mode=*) shift ;;
    --dir) DIR="${2:?--dir needs a value}"; shift 2 ;;
    --dir=*) DIR="${1#*=}"; shift ;;
    --fix) FIX=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$DIR" ] || DIR="$(pwd)"
[ -d "$DIR" ] || die "no such directory: $DIR"
DIR="$(cd "$DIR" && pwd -P)"
ENV_FILE="$DIR/.env"
[ -f "$ENV_FILE" ] || die "no $ENV_FILE in $DIR — pass --dir with the deployment directory"

env_get() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }
# The last assignment wins for systemd and Node's own .env loader, so
# that is the value the runtime actually sees.
env_last() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1; }

MODE=native
SERVICE_USER="${SERVICE_USER:-dsh}"
PROBLEMS=0
WARNINGS=0

ok()   { [ "$QUIET" = 1 ] && return 0; say ok   "$1" "$2"; }
warns(){ WARNINGS=$((WARNINGS + 1)); say warn "$1" "$2"; }
fails(){ PROBLEMS=$((PROBLEMS + 1)); say fail "$1" "$2"; }
fixed(){ say fix  "$1" "$2"; }

# Rewrite .env in one atomic pass: drop duplicate assignments (last wins, as the
# runtime reads them), strip the CR a Windows editor leaves, quote nothing, and
# keep every comment and unknown key where it was.
normalize_env() {
  local tmp duplicate=0
  tmp="$(mktemp)"
  # Two passes: count the duplicate keys, then keep the last line of each.
  duplicate="$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ { key=$1; n[key]++ } END { for (k in n) if (n[k] > 1) c++; print c + 0 }' "$ENV_FILE")"
  awk -F= '
    /^[A-Za-z_][A-Za-z0-9_]*=/ { key=$1; last[key]=NR }
    { line[NR]=$0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (line[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
          split(line[i], parts, "=")
          if (last[parts[1]] != i) continue
          sub(/\r$/, "", line[i])
        }
        print line[i]
      }
    }
  ' "$ENV_FILE" > "$tmp"
  # A file without a trailing newline makes the next appended key unreadable.
  if [ -s "$tmp" ] && [ "$(tail -c 1 "$tmp" | wc -l)" = 0 ]; then
    printf '\n' >> "$tmp"
  fi
  if cmp -s "$tmp" "$ENV_FILE"; then
    rm -f "$tmp"
    [ "$duplicate" = 0 ] || fixed env-file "$duplicate duplicated key(s) collapsed to their last value"
    return 0
  fi
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
  [ "$duplicate" = 0 ] && fixed env-file "normalized line endings and trailing newline" \
    || fixed env-file "$duplicate duplicated key(s) collapsed to their last value"
}

check_env_file() {
  [ -r "$ENV_FILE" ] || { fails env-file "$ENV_FILE is not readable"; return; }
  local cr_keys dupes keys
  dupes="$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ { n[$1]++ } END { for (k in n) if (n[k] > 1) print k " x" n[k] }' "$ENV_FILE")"
  cr_keys="$(grep -c $'\r' "$ENV_FILE" 2>/dev/null || true)"
  local mode_bits
  mode_bits="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '')"
  if [ -n "$dupes" ] || [ "${cr_keys:-0}" -gt 0 ]; then
    if [ "$FIX" = 1 ]; then
      normalize_env
      dupes="$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ { n[$1]++ } END { for (k in n) if (n[k] > 1) print k }' "$ENV_FILE")"
      [ -z "$dupes" ] || fails env-file "keys still assigned twice: $dupes"
      grep -q $'\r' "$ENV_FILE" 2>/dev/null && fails env-file "CR characters survive in $ENV_FILE"
    else
      [ -n "$dupes" ] && fails env-file "assigned more than once: $(printf '%s' "$dupes" | tr '\n' ' ')— run --fix"
      [ "${cr_keys:-0}" -gt 0 ] && fails env-file "$cr_keys line(s) end with CR (a Windows editor) — run --fix"
    fi
  else
    ok env-file "one value per key, no CR characters"
  fi
  case "$mode_bits" in
    600|640|'' ) ok env-file "mode ${mode_bits:-unknown}" ;;
    4??|6??|7??) fails env-file ".env is mode $mode_bits — it holds the bot token, the provider key and the updater token" ;;
    *) warns env-file ".env is mode $mode_bits; 600 is the intended one" ;;
  esac
  if [ "$FIX" = 1 ]; then
    chown "root:$SERVICE_USER" "$ENV_FILE" 2>/dev/null || true
    chmod 640 "$ENV_FILE" 2>/dev/null || true
  fi
}

provider_key_env() {
  local provider="${1:-}"
  case "$provider" in
    opencode-go) printf %s OPENCODE_GO_API_KEY ;;
    deepseek-official) printf %s DEEPSEEK_API_KEY ;;
    *) printf %s "${DSH_PROVIDER_API_KEY_ENV:-DSH_PROVIDER_API_KEY}" ;;
  esac
}

check_provider_key() {
  local provider key_var key
  provider="$(env_last DSH_PROVIDER)"; [ -n "$provider" ] || provider=opencode-go
  key_var="$(env_last DSH_PROVIDER_API_KEY_ENV)"
  [ -n "$key_var" ] || key_var="$(provider_key_env "$provider")"
  key="$(env_last "$key_var")"
  if [ -z "$key" ]; then
    warns provider-key "$key_var is empty — the runtime boots and every model call fails"
    return
  fi
  case "$key" in
    *[[:space:]]*|*\"*|*\'*|*\\*)
      fails provider-key "$key_var contains whitespace, quotes or a backslash; the HTTP header rejects it" ;;
    *)
      if [ "${#key}" -lt 16 ]; then
        warns provider-key "$key_var is only ${#key} characters — check it was pasted whole"
      else
        ok provider-key "$key_var is set (${#key} characters)"
      fi ;;
  esac
}

# The stored credential wins over the environment. Compare it without ever
# printing either value: `status` answers match/different/absent.
check_credential_store() {
  local node="${NODE_BIN:-node}"
  local home="$DATA_DIR/home"
  [ -f "$home/.credentials.yaml" ] || { ok credential-store "no stored credential (the environment is authoritative)"; return; }
  local provider key_var key
  provider="$(env_last DSH_PROVIDER)"; [ -n "$provider" ] || provider=opencode-go
  key_var="$(env_last DSH_PROVIDER_API_KEY_ENV)"
  [ -n "$key_var" ] || key_var="$(provider_key_env "$provider")"
  key="$(env_last "$key_var")"
  if ! command -v "$node" >/dev/null 2>&1; then
    warns credential-store "cannot inspect $home/.credentials.yaml without node; if a key was saved in the web UI it overrides .env"
    return
  fi
  local state status
  state="$(DSH_VALUE="$key" "$node" "$SCRIPT_DIR/credentials.mjs" status --home "$home" --ref "$key_var" 2>/dev/null)" || {
    warns credential-store "cannot read $home/.credentials.yaml (fix it or remove it)"
    return
  }
  case "$state" in
    absent)
      ok credential-store "no stored copy of $key_var" ;;
    match)
      ok credential-store "stored copy of $key_var matches .env" ;;
    present)
      warns credential-store "a key for $key_var is stored in the web UI but .env has none; the stored one is used" ;;
    different*)
      if [ "$FIX" = 1 ] && [ -n "$key" ]; then
        DSH_VALUE="$key" "$node" "$SCRIPT_DIR/credentials.mjs" sync --home "$home" --ref "$key_var" >/dev/null 2>&1
        chown "$RUNTIME_UID:$RUNTIME_GID" "$home/.credentials.yaml" "$home/.credentials.yaml.bak" 2>/dev/null || true
        fixed credential-store "stored copy of $key_var updated to the .env value (backup: .credentials.yaml.bak)"
      else
        fails credential-store "the web UI stores a different $key_var, which overrides .env — rerun with --fix, or save the same key in Settings → Models"
      fi ;;
    *)
      warns credential-store "unexpected state '$state' for $key_var" ;;
  esac
}

# The entrypoint manages marker-delimited blocks. Two copies mean an interrupted
# write or a hand edit; the profile then mounts the plugin twice.
check_patch() {
  local patch="$DATA_DIR/home/profiles/web/cordis.patch.yml"
  [ -f "$patch" ] || { ok patch "no profile patch yet (first boot writes it)"; return; }
  local -a unbalanced=() duplicated=()
  local key start end
  for key in dsh-provider dsh-telegram dsh-penpot; do
    start="$(grep -c "^# >>> $key" "$patch" 2>/dev/null || true)"
    end="$(grep -c "^# <<< $key" "$patch" 2>/dev/null || true)"
    if [ "${start:-0}" != "${end:-0}" ]; then unbalanced+=("$key"); fi
    if [ "${start:-0}" -gt 1 ]; then duplicated+=("$key"); fi
  done
  if [ "${#unbalanced[@]}" -eq 0 ] && [ "${#duplicated[@]}" -eq 0 ]; then
    ok patch "managed blocks are balanced and unique"
    return
  fi
  if [ "$FIX" = 1 ] && [ "${#unbalanced[@]}" -eq 0 ]; then
    # Keep the first copy of each block: the entrypoint writes identical blocks,
    # so the first one sits where the user's ordering expects it.
    local tmp
    tmp="$(mktemp)"
    awk '
      /^# >>> / {
        key = $3
        if (seen[key]++) { skipping = 1; next }
      }
      !skipping { print }
      /^# <<< / { skipping = 0 }
    ' "$patch" > "$tmp"
    if [ -s "$tmp" ]; then
      cat "$tmp" > "$patch"
      rm -f "$tmp"
      fixed patch "removed duplicated managed block(s): ${duplicated[*]}"
    else
      rm -f "$tmp"
      fails patch "cannot rewrite $patch safely — inspect it by hand"
    fi
  else
    fails patch "unbalanced (${unbalanced[*]:-none}) or duplicated (${duplicated[*]:-none}) managed block(s) — rerun with --fix"
  fi
}

# Two runtimes on one data directory: each holds the other's session locks, the
# web UI of one shows a stale workspace list, and Telegram reports "held by
# another client" after a restart. The guard in entrypoint.sh takes the lock;
# this reports who holds it.
check_instance() {
  local marker="$DATA_DIR/.runtime.json"
  [ -f "$marker" ] || { ok instance "no runtime marker in $DATA_DIR"; return; }
  local pid mode started
  pid="$(sed -n 's/.*"pid":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$marker" | head -1)"
  mode="$(sed -n 's/.*"mode":[[:space:]]*"\([^"]*\)".*/\1/p' "$marker" | head -1)"
  started="$(sed -n 's/.*"startedAt":[[:space:]]*"\([^"]*\)".*/\1/p' "$marker" | head -1)"
  if [ -z "$pid" ]; then
    # A marker without a pid is either from a runtime that never finished
    # writing it or from a build that wrote an older shape. It names no holder,
    # so it is a warning with the recovery, not a failure: the running runtime
    # rewrites the file at every boot.
    warns instance "${marker} has no readable pid — restart dsh.service to rewrite it"
    return
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    ok instance "no live runtime holds $DATA_DIR (stale marker from pid $pid)"
    return
  fi
  if [ "${mode:-}" = "$MODE" ]; then
    ok instance "the $MODE runtime owns $DATA_DIR (pid $pid, since ${started:-?})"
  else
    fails instance "a ${mode:-?} runtime is using $DATA_DIR (pid $pid, since ${started:-?}) — stop it before starting $MODE"
  fi
}

# The web UI lists what the runtime's workspace registry loads. A document that
# does not parse makes the plugin fail to activate: the UI shows nothing while
# Telegram still lists its own bindings — the exact disagreement users report as
# "the web UI lost my workspace". A path that vanished leaves an empty-looking
# workspace the UI still shows. Neither is safe to rewrite automatically, but
# both must be named, with the snapshot that restores them.
check_registry() {
  local file="$DATA_DIR/home/storages/workspace.json"
  [ -f "$file" ] || { ok registry "no workspace registry yet (first boot writes it)"; return; }
  if ! command -v node >/dev/null 2>&1; then
    warns registry "cannot inspect $file without node"
    return
  fi
  local report
  report="$(node -e '
    const fs = require("node:fs")
    const file = process.argv[1]
    let doc
    try { doc = JSON.parse(fs.readFileSync(file, "utf8")) } catch (error) {
      console.log("corrupt|" + (error instanceof Error ? String(error.message).split("\n")[0] : String(error)))
      process.exit(0)
    }
    const table = (doc.tables && doc.tables.workspaces) || {}
    const rows = Object.values(table)
    const missing = rows.filter((row) => {
      try { return !fs.statSync(row.path).isDirectory() } catch { return true }
    })
    console.log("ok|" + rows.length + "|" + missing.length + "|" + missing.slice(0, 3).map((row) => row.path).join(", "))
  ' "$file" 2>/dev/null)" || report="unknown"
  case "$report" in
    ok\|*)
      local count missing paths
      count="$(printf '%s' "$report" | cut -d'|' -f2)"
      missing="$(printf '%s' "$report" | cut -d'|' -f3)"
      paths="$(printf '%s' "$report" | cut -d'|' -f4)"
      if [ "${missing:-0}" -gt 0 ]; then
        warns registry "$count workspace(s), $missing with a missing directory ($paths) — their sessions cannot attach"
      else
        ok registry "$count workspace(s), every directory present"
      fi ;;
    corrupt\|*)
      fails registry "the workspace registry does not parse ($(printf '%s' "$report" | cut -d'|' -f2)) — restore data/home from backups/self-*.tgz, or move the file aside to rebuild it from session logs" ;;
    *)
      warns registry "cannot read $file" ;;
  esac
}

check_version() {
  local file="$DIR/VERSION" recorded
  [ -f "$file" ] || { ok version "no VERSION file in $DIR (image deployments have none)"; return; }
  recorded="$(env_last DSH_SETUP_VERSION)"
  if [ -z "$recorded" ]; then
    if [ "$FIX" = 1 ]; then
      printf 'DSH_SETUP_VERSION=%s\n' "$(tr -d '\n' < "$file")" >> "$ENV_FILE"
      fixed version "recorded $(tr -d '\n' < "$file") in .env"
    else
      warns version ".env does not record DSH_SETUP_VERSION (checkout is $(tr -d '\n' < "$file"))"
    fi
    return
  fi
  if [ "$recorded" = "$(tr -d '\n' < "$file")" ]; then
    ok version "$recorded matches the checkout"
  else
    warns version ".env says $recorded but the checkout is $(tr -d '\n' < "$file") — an update is half-applied?"
  fi
}

check_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warns service "systemctl is missing on this host"; return
  fi
  if systemctl is-active --quiet dsh.service 2>/dev/null; then
    ok service "dsh.service is active"
  else
    fails service "dsh.service is not active — journalctl -u dsh.service -n 40"
  fi
  if systemctl is-active --quiet dsh-updater.service 2>/dev/null; then
    ok service "dsh-updater.service is active"
  else
    warns service "dsh-updater.service is not active — /system update all will be unavailable"
  fi
}

check_web() {
  local port bind
  port="$(env_last DSH_PORT)"; port="${port:-4310}"
  bind="$(env_last DSH_BIND_IP)"; bind="${bind:-127.0.0.1}"
  # A TCP connect is the honest check: a process listening on the wrong
  # interface looks healthy to `ss` and unreachable to the phone.
  if (exec 3<>"/dev/tcp/$bind/$port") 2>/dev/null; then
    exec 3>&- 2>/dev/null || true
    ok web "http://$bind:$port/ accepts connections"
  else
    warns web "nothing accepts connections on $bind:$port — check the bind address and the firewall"
  fi
}

check_data_owner() {
  [ -d "$DATA_DIR" ] || return 0
  local owner want
  owner="$(stat -c '%u:%g' "$DATA_DIR" 2>/dev/null || true)"
  [ -n "$owner" ] || return 0
  want="$RUNTIME_UID:$RUNTIME_GID"
  if [ "$owner" = "$want" ]; then
    ok data-owner "$DATA_DIR is owned by $want"
  elif [ "$FIX" = 1 ] && [ "$(id -u)" = 0 ]; then
    chown -R "$want" "$DATA_DIR" 2>/dev/null || true
    fixed data-owner "$DATA_DIR chowned to $want"
  else
    fails data-owner "$DATA_DIR is owned by $owner, not $want — the runtime cannot write there"
  fi
}

main() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  DATA_DIR="$DIR/data"
  # `sudo ./install.sh` runs this as root; the files it touches belong to the
  # runtime user, so every repair is chowned afterwards.
  RUNTIME_UID="$(id -u "$SERVICE_USER" 2>/dev/null || echo 0)"
  RUNTIME_GID="$(id -g "$SERVICE_USER" 2>/dev/null || echo 0)"
  log "checking deployment in $DIR"
  check_env_file
  check_provider_key
  check_credential_store
  check_patch
  check_registry
  check_instance
  check_version
  check_service
  check_web
  check_data_owner
  echo
  if [ "$PROBLEMS" -gt 0 ]; then
    log "$PROBLEMS problem(s), $WARNINGS warning(s)$([ "$FIX" = 1 ] || echo ' — rerun with --fix')"
    return 1
  fi
  log "clean ($WARNINGS warning(s))"
  return 0
}

main
