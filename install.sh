#!/usr/bin/env bash
#
# One-command installer for the DSH setup.
#
#   ./install.sh                        interactive: asks for the few values
#                                        that are easy to get wrong
#   ./install.sh --check                print the plan, change nothing
#   ./install.sh --yes                  unattended, all defaults
#   ./install.sh --config answers.env   answers from a file (see install.example.env)
#
# The deployment is a systemd service on this host: the agent runs as an
# unprivileged user and can read the host's files; the updater runs as root
# because only it may restart the service. Read docs/HOST.md first.
#
# Everything the installer decides is printed as a plan first. With --check the
# plan is all that happens, which is what the test suite exercises.
set -euo pipefail

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# Where this file is, without assuming it is a file at all: `wget -qO- … | bash`
# has no path, and that is exactly the case the bootstrap below handles.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
else
  SRC_DIR="$(pwd -P)"
fi

# ===========================================================================
# Bootstrap: one downloaded file is enough.
#
#   wget -qO- https://raw.githubusercontent.com/…/install.sh | bash -s -- --yes
#
# The installer needs VERSION and the entrypoint beside it, so a lone copy
# fetches a release checkout and re-runs the copy
# inside it. Everything here is about getting that checkout; the installer
# proper starts below.
# ===========================================================================
SETUP_REPO="${DSH_SETUP_REPO:-https://github.com/vladtsvirko/dsh-tg-docker-setup.git}"

bootstrap_usage() {
  cat <<'EOF'
Get the setup from the internet and install it.

  wget -qO- https://raw.githubusercontent.com/vladtsvirko/dsh-tg-docker-setup/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/vladtsvirko/dsh-tg-docker-setup/main/install.sh | bash -s -- --yes

Options (bootstrap):
  --ref REF              release tag to fetch (default: the newest on the remote)
  --dir PATH             where to put the checkout (default: /opt/dsh-setup as
                         root, ~/dsh-setup otherwise)
  --check                show what would be fetched and installed, change nothing
  --no-deps              do not install Node or git (they must already exist)
  -h, --help             this text

Everything else is passed to the installer inside the checkout: --yes,
--config, --design, --uninstall. Run --help after the checkout for the
full list.
EOF
}

in_bootstrap() {
  [ -f "$SRC_DIR/VERSION" ] && [ -f "$SRC_DIR/entrypoint.sh" ] && return 1
  return 0
}

# The newest release tag, without the GitHub API and without jq.
bootstrap_latest() {
  local tags
  tags="$(git ls-remote --tags --sort=-v:refname "$SETUP_REPO" 'v*' 2>/dev/null \
    | sed -e 's#.*refs/tags/##' -e 's#\^{}$##' | sort -u -r -V | head -1)" || true
  printf '%s' "$tags"
}

# apt, but only when it is there and only for packages that are missing.
bootstrap_apt() {
  local -a missing=("$@")
  [ "${#missing[@]}" -gt 0 ] || return 0
  if ! command -v apt-get >/dev/null 2>&1; then
    die "missing ${missing[*]} — install them with your package manager and run this again"
  fi
  local -a as=()
  if [ "$(id -u)" != 0 ]; then
    command -v sudo >/dev/null 2>&1 \
      || die "installing ${missing[*]} needs root — run with sudo, or install them yourself"
    as=(sudo)
  fi
  log "installing ${missing[*]}"
  ${as[@]:-} env DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt-get update failed; trying the install anyway"
  ${as[@]:-} env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}"
}

bootstrap() {
  local -a args=("$@")
  local ref="" dir="" check=0 no_deps=0 i=0 arg
  while [ "$i" -lt "${#args[@]}" ]; do
    arg="${args[$i]}"
    case "$arg" in
      -h|--help) bootstrap_usage; exit 0 ;;
      --ref)   ref="${args[$((i + 1))]:-}"; i=$((i + 2)); continue ;;
      --ref=*) ref="${arg#*=}" ;;
      --dir)   dir="${args[$((i + 1))]:-}"; i=$((i + 2)); continue ;;
      --dir=*) dir="${arg#*=}" ;;
      --check) check=1 ;;
      --no-deps) no_deps=1 ;;
    esac
    i=$((i + 1))
  done

  echo
  log "the setup is not here — fetching a release first"
  [ -n "$ref" ] || ref="${DSH_SETUP_REF:-}"
  [ -n "$dir" ] || dir="${DSH_SETUP_DIR:-}"
  if [ -z "$dir" ]; then
    if [ "$(id -u)" = 0 ]; then dir=/opt/dsh-setup; else dir="$HOME/dsh-setup"; fi
  fi

  printf '    repository: %s\n' "$SETUP_REPO"
  printf '    release:    %s\n' "${ref:-the newest tag on the remote}"
  printf '    directory:  %s\n' "$dir"
  printf '    needs:      git, curl (installed if missing); Podman and Node are handled\n'
  printf '                by the installer, once the mode is known\n'
  echo

  if [ "$check" = 1 ]; then
    if ! command -v git >/dev/null 2>&1; then
      log "check only — install git to preview the full plan"
      exit 0
    fi
    # A plan is worth reading before anything is installed, so fetch a throwaway
    # checkout and let the real installer print its plan against the deployment
    # directory the user asked for.
    log "fetching ${ref:-the newest tag} to preview the plan (temporary checkout)"
    [ -n "$ref" ] || ref="$(bootstrap_latest)"
    [ -n "$ref" ] || die "cannot read release tags from $SETUP_REPO — pass --ref v<version>"
    local preview code
    preview="$(mktemp -d)"
    if ! git -c advice.detachedHead=false clone --quiet --branch "$ref" "$SETUP_REPO" "$preview"; then
      rm -rf "$preview"
      die "cannot clone $SETUP_REPO at $ref"
    fi
    ( cd "$preview" && bash "$preview/install.sh" --check "${args[@]}" --dir "$dir" )
    code=$?
    rm -rf "$preview"
    exit $code
  fi

  # git and curl to fetch, and nothing else here: the mode decides whether
  # Podman or Node is needed, and that question is asked after the checkout.
  local -a want=()
  command -v git >/dev/null 2>&1 || want+=(git)
  command -v curl >/dev/null 2>&1 && command -v wget >/dev/null 2>&1 || want+=(curl)
  if [ "${#want[@]}" -gt 0 ]; then
    bootstrap_apt "${want[@]}"
  fi

  command -v git >/dev/null 2>&1 || die "git is required to fetch the setup"
  [ -n "$ref" ] || ref="$(bootstrap_latest)"
  if [ -z "$ref" ]; then
    die "cannot read release tags from $SETUP_REPO — pass --ref v<version>"
  fi

  if [ -d "$dir/.git" ]; then
    log "updating the checkout in $dir"
    git -C "$dir" fetch --quiet --tags origin || warn "cannot fetch tags; using what is there"
    git -C "$dir" checkout --quiet "$ref" || die "cannot check out $ref in $dir"
  else
    log "fetching $ref into $dir"
    mkdir -p "$(dirname "$dir")"
    git -c advice.detachedHead=false clone --quiet --branch "$ref" "$SETUP_REPO" "$dir" \
      || die "cannot clone $SETUP_REPO at $ref"
  fi
  # A root install with sudo must not leave the tree owned by root: the data
  # directory lives inside it.
  if [ "$(id -u)" = 0 ] && [ -n "${SUDO_UID:-}" ]; then
    chown -R "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$dir" 2>/dev/null || true
  fi

  log "installing from $dir"
  cd "$dir"
  exec env DSH_BOOTSTRAP_SOURCE="$dir" bash "$dir/install.sh" "${args[@]}"
}

if in_bootstrap; then
  bootstrap "$@"
  exit 0
fi

cd "$SRC_DIR"
SETUP_VERSION="$(tr -d '\n' < "$SRC_DIR/VERSION")"
DSH_VERSION="$(printf '%s' "$SETUP_VERSION" | sed -E 's/-[0-9]+\.[0-9]+\.[0-9]+$//')"

CONTAINERS="" CONTAINERS_SET=0 DESIGN_SET=0 DIR="" CONFIG="" REF="" CHECK=0 YES=0 UNINSTALL=0 PURGE=0 DEPS=1 CLEAN_SOURCE=0
DOCTOR=0 FIX=0 ROTATE_KEY=0
SERVICE_USER="${SERVICE_USER:-dsh}"
DSH_PORT="${DSH_PORT:-}"
DSH_BIND_IP="${DSH_BIND_IP:-}"
DSH_PROVIDER="${DSH_PROVIDER:-}"
DSH_MODEL="${DSH_MODEL:-}"
DSH_RESOURCE_PERCENT="${DSH_RESOURCE_PERCENT:-}"
DSH_PUBLIC_URL="${DSH_PUBLIC_URL:-}"
DSH_TELEGRAM_BOT_TOKEN="${DSH_TELEGRAM_BOT_TOKEN:-}"
ALLOWED_USER_IDS="${ALLOWED_USER_IDS:-}"
DSH_ADMIN_USER_ID="${DSH_ADMIN_USER_ID:-}"
DSH_TELEGRAM_PUBLISHER_TOKENS="${DSH_TELEGRAM_PUBLISHER_TOKENS:-}"
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-}"
GIT_PROVIDER="${GIT_PROVIDER:-}"
GIT_TOKEN="${GIT_TOKEN:-}"
GIT_HOST="${GIT_HOST:-}"
GIT_AUTH="${GIT_AUTH:-}"
GIT_KEY="${GIT_KEY:-}"
GIT_KNOWN_HOSTS="${GIT_KNOWN_HOSTS:-}"
GIT_PROFILES_FILE="${GIT_PROFILES_FILE:-}"
CONTAINERS="${CONTAINERS:-}"
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
  ./install.sh --yes                  unattended, all defaults
  ./install.sh --config answers.env   answers from a file

Without a checkout — one small file fetches the release, then installs Node,
git and the systemd units:

  wget -qO- https://raw.githubusercontent.com/vladtsvirko/dsh-tg-docker-setup/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/vladtsvirko/dsh-tg-docker-setup/main/install.sh | bash -s -- --yes

Options:
  --containers podman|none
                         rootless Podman for the agent's disposable containers
                         (default: podman; Docker is never installed)
  --dir PATH             deployment directory (default: /srv/dsh)
  --design penpot|none   optional Penpot design stack, run on Podman
                         (default: ask, else none)
  --ref REF              git ref for the native checkout (default: v<VERSION>)
  --config FILE          read answers from FILE (KEY=VALUE, no shell);
                         still prompts unless --yes is passed
  --no-deps              do not install Node or git; they must already exist
  --clean-source         remove the downloaded checkout once installed
  --yes, -y              accept defaults, never prompt
  --check                print the plan and change nothing
  --doctor               check this deployment and report; change nothing
  --fix                  repair what the check can repair (implies --doctor)
  --rotate-key           ask for the provider key again (default: keep the
                         deployed OPENCODE_GO_API_KEY / DEEPSEEK_API_KEY)
  --uninstall            stop and remove the deployment (keeps data/)
  --purge                with --uninstall: also delete data/, .env and backups/
  --version              print the setup and DSH versions, then exit
  -h, --help             this text
EOF
}

# --- answers from a file ---------------------------------------------------
# Strict KEY=VALUE parsing: no sourcing, so a config file cannot execute code.
CONFIG_KEYS="CONTAINERS DIR SERVICE_USER DSH_PORT DSH_BIND_IP DSH_PUBLIC_URL DSH_PROVIDER DSH_MODEL DSH_RESOURCE_PERCENT
DSH_TELEGRAM_BOT_TOKEN ALLOWED_USER_IDS DSH_ADMIN_USER_ID DSH_UPDATER_TOKEN DESIGN DSH_DESIGN_PORT PROVIDER_KEY
DSH_TELEGRAM_PUBLISHER_TOKENS GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_PROVIDER GIT_TOKEN GIT_HOST
GIT_AUTH GIT_KEY GIT_KNOWN_HOSTS GIT_PROFILES_FILE"
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
    case "$key" in
      DESIGN) DESIGN_SET=1 ;;
      CONTAINERS) CONTAINERS_SET=1 ;;
    esac
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
    --containers) CONTAINERS="${2:?--containers needs a value}"; CONTAINERS_SET=1; shift 2 ;;
    --containers=*) CONTAINERS="${1#*=}"; CONTAINERS_SET=1; shift ;;
    --design) DESIGN="${2:?--design needs a value}"; DESIGN_SET=1; shift 2 ;;
    --design=*) DESIGN="${1#*=}"; DESIGN_SET=1; shift ;;
    --ref)    REF="${2:?--ref needs a value}"; shift 2 ;;
    --ref=*)  REF="${1#*=}"; shift ;;
    --dir)    DIR="${2:?--dir needs a value}"; shift 2 ;;
    --dir=*)  DIR="${1#*=}"; shift ;;
    --config) shift 2 ;;
    --config=*) shift ;;
    --yes|-y) YES=1; shift ;;
    --check)  CHECK=1; shift ;;
    --no-deps) DEPS=0; shift ;;
    --clean-source) CLEAN_SOURCE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge)  PURGE=1; shift ;;
    --doctor) DOCTOR=1; shift ;;
    --fix)    FIX=1; shift ;;
    --rotate-key) ROTATE_KEY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) printf 'dsh-setup %s (DSH %s)\n' "$SETUP_VERSION" "$DSH_VERSION"; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done


if [ "$PURGE" = 1 ] && [ "$UNINSTALL" != 1 ]; then
  die "--purge only makes sense with --uninstall"
fi

# --- prompts ---------------------------------------------------------------
# `wget … | bash` leaves stdin as the script itself, so a prompt has to read the
# terminal directly or the install silently takes every default.
can_ask() {
  [ "$YES" = 1 ] && return 1
  [ "$CHECK" = 1 ] && return 1
  [ -t 0 ] && return 0
  # A readable /dev/tty is not the same as a usable one: opening it fails with
  # "no such device" when the process has no controlling terminal (CI, cron).
  ( : </dev/tty ) 2>/dev/null
}

read_from_terminal() {
  local answer=""
  if [ -t 0 ]; then read -r answer || answer=""; else read -r answer </dev/tty || answer=""; fi
  printf '%s' "$answer"
}

ask() {
  local var="$1" prompt="$2" def="${3:-}" current answer
  current="${!var:-}"
  [ -n "$current" ] && def="$current"
  if ! can_ask; then
    printf -v "$var" '%s' "$def"
    return 0
  fi
  printf '%s [%s]: ' "$prompt" "$def" >&2
  answer="$(read_from_terminal)"
  printf -v "$var" '%s' "${answer:-$def}"
}

# Like ask_secret, but an existing value is kept unless the user types a new
# one, and the value is never echoed (publisher tokens are secrets too).
ask_secret_keep() {
  local var="$1" prompt="$2" current answer
  current="${!var:-}"
  if ! can_ask; then return 0; fi
  if [ -n "$current" ]; then
    printf '%s (blank = keep current): ' "$prompt" >&2
  else
    printf '%s (blank = none): ' "$prompt" >&2
  fi
  if [ -t 0 ]; then read -r -s answer || answer=""; else read -r -s answer </dev/tty || answer=""; fi
  printf '\n'
  if [ -n "$answer" ]; then printf -v "$var" '%s' "$answer"; fi
}

ask_secret() {
  local var="$1" prompt="$2" blank="${3-disabled}" current answer
  current="${!var:-}"
  if [ -n "$current" ] || ! can_ask; then
    [ -n "$current" ] || printf -v "$var" '%s' ''
    return 0
  fi
  if [ "$blank" = "" ]; then
    printf '%s: ' "$prompt" >&2
  else
    printf '%s (blank = %s): ' "$prompt" "$blank" >&2
  fi
  if [ -t 0 ]; then read -r -s answer || answer=""; else read -r -s answer </dev/tty || answer=""; fi
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

# --- repository access: accounts and the manifest --------------------------
# One install can hold several git accounts (GitHub, GitLab, a self-hosted
# forge). One account is written as `default` (the historical shape); two or
# more become host-scoped entries so a token for one forge is never offered to
# another. scripts/git-manifest.mjs does the merge, so a repair adds accounts
# instead of replacing the file.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

GIT_ENTRIES_JSON=""

# A preset host, or empty for providers that must be told.
git_preset_host() {
  case "$1" in
    github) printf 'github.com' ;;
    gitlab) printf 'gitlab.com' ;;
    *) printf '' ;;
  esac
}

# Resolve a key/known_hosts answer: a bare name lives in secrets/git, an
# absolute path is used as given.
git_secret_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/secrets/git/%s' "$DIR" "$1" ;;
  esac
}

# git_add_entry <provider> <host> <auth> <token> <key> <known_hosts>
git_add_entry() {
  local entry
  entry="{\"provider\":\"$(json_escape "$1")\",\"host\":\"$(json_escape "$2")\",\"auth\":\"$(json_escape "$3")\""
  if [ "$3" = https ]; then
    entry="$entry,\"token\":\"$(json_escape "$4")\"}"
  else
    entry="$entry,\"key\":\"$(json_escape "$5")\",\"known_hosts\":\"$(json_escape "$6")\"}"
  fi
  if [ -z "$GIT_ENTRIES_JSON" ]; then
    GIT_ENTRIES_JSON="[$entry]"
  else
    GIT_ENTRIES_JSON="${GIT_ENTRIES_JSON%]},$entry]"
  fi
}

ask_git_accounts() {
  local provider host auth token key known more first=1
  [ -z "$GIT_PROFILES_FILE" ] || return 0
  # A repair adds to what is there; say what that is, so "none" is an informed
  # choice rather than a silent skip.
  if [ -f "$DIR/secrets/git/profiles.json" ] && command -v node >/dev/null 2>&1; then
    existing="$(node -e 'const m=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")); const h=[]; if(m.default) h.push(m.default.host||m.default.provider); for (const k of Object.keys(m.hosts||{})) h.push(k); console.log(h.join(", "))' "$DIR/secrets/git/profiles.json" 2>/dev/null || true)"
    [ -n "$existing" ] && printf '    existing git accounts: %s\n' "$existing" >&2
  fi
  ask GIT_PROVIDER "Add a git account (github/gitlab/gitea/forgejo/self-hosted/none) — existing accounts are kept" none
  case "$GIT_PROVIDER" in
    ""|none|None) GIT_PROVIDER=""; return 0 ;;
    github|gitlab|gitea|forgejo|self-hosted) ;;
    *) warn "unknown git provider '$GIT_PROVIDER' — skipping repository access"; GIT_PROVIDER=""; return 0 ;;
  esac
  more=1
  while [ "$more" = 1 ]; do
    provider="$GIT_PROVIDER"
    if [ "$first" != 1 ]; then
      # A second account starts from blank answers, not the previous token or
      # the previous "yes, add another" (which would otherwise loop forever).
      GIT_HOST="" GIT_AUTH="" GIT_TOKEN="" GIT_KEY="" GIT_KNOWN_HOSTS=""
      GIT_ADD_MORE="" GIT_USE_GH="" GIT_GENERATE=""
    fi
    first=0
    host="$(git_preset_host "$provider")"
    case "$provider" in
      gitea|forgejo|self-hosted)
        ask GIT_HOST "Host name (for example git.example.com)" ""
        host="$GIT_HOST"
        [ -n "$host" ] || { warn "no host given — skipping this account"; provider=""; }
        ;;
    esac
    if [ -n "$provider" ]; then
      ask GIT_AUTH "Authentication (https/ssh)" "https"
      case "$GIT_AUTH" in
        https|HTTPS) auth=https ;;
        ssh|SSH) auth=ssh ;;
        *) warn "unknown auth '$GIT_AUTH' — skipping this account"; provider="" ;;
      esac
    fi
    if [ -n "$provider" ] && [ "$auth" = https ]; then
      token=""
      # GitHub has more than one way to get a token: a PAT, or the one the
      # GitHub CLI already stores. Offer the CLI when it is logged in.
      if [ "$provider" = github ] && command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
        ask GIT_USE_GH "Use the token from 'gh auth login'? (y/N)" n
        case "$GIT_USE_GH" in y|Y|yes|Yes) token="$(gh auth token 2>/dev/null || true)" ;; esac
      fi
      if [ -z "$token" ]; then
        ask_secret GIT_TOKEN "Access token for $provider (blank = skip this account)" ""
        token="$GIT_TOKEN"
      fi
      if [ -n "$token" ]; then
        git_add_entry "$provider" "$host" https "$token" "" ""
        log "repository access: $provider over HTTPS ($host)"
      else
        warn "no token — $provider skipped"
      fi
    elif [ -n "$provider" ]; then
      ask GIT_KEY "Private key (name under secrets/git, or absolute path)" "${provider}_ed25519"
      ask GIT_KNOWN_HOSTS "known_hosts (name under secrets/git, or absolute path)" "known_hosts"
      key="$(git_secret_path "$GIT_KEY")"
      known="$(git_secret_path "$GIT_KNOWN_HOSTS")"
      if [ ! -f "$key" ] && command -v ssh-keygen >/dev/null 2>&1; then
        ask GIT_GENERATE "No key at $key — generate an ed25519 key now? (y/N)" n
        case "$GIT_GENERATE" in
          y|Y|yes|Yes)
            mkdir -p "$(dirname "$key")" && chmod 700 "$(dirname "$key")" 2>/dev/null || true
            if ssh-keygen -q -t ed25519 -N '' -C "${GIT_AUTHOR_EMAIL:-dsh}" -f "$key" >/dev/null 2>&1; then
              chmod 600 "$key" 2>/dev/null || true
              log "generated $key"
              printf '    public key — add it to %s as a deploy key:\n' "$host"
              sed 's/^/      /' "$key.pub" 2>/dev/null || true
            else
              warn "ssh-keygen failed — create $key yourself"
            fi
          ;;
        esac
      fi
      [ -f "$key" ] || warn "no private key at $key — SSH to $host will fail until it exists"
      [ -f "$known" ] || warn "no known_hosts at $known — create it with: ssh-keyscan $host >> $known"
      git_add_entry "$provider" "$host" ssh "" "$GIT_KEY" "$GIT_KNOWN_HOSTS"
      log "repository access: $provider over SSH ($host)"
    fi
    ask GIT_ADD_MORE "Add another git account? (y/N)" n
    case "$GIT_ADD_MORE" in
      y|Y|yes|Yes)
        GIT_PROVIDER=""
        ask GIT_PROVIDER "Next git host (github/gitlab/gitea/forgejo/self-hosted)" github
        case "$GIT_PROVIDER" in
          github|gitlab|gitea|forgejo|self-hosted) ;;
          *) warn "unknown git provider '$GIT_PROVIDER' — stopping"; more=0 ;;
        esac
      ;;
      *) more=0 ;;
    esac
  done
}

# What the deployed manifest already holds, without printing any secret. A
# repair keeps this file; the plan must say so instead of "none".
git_manifest_summary() {
  local file="$DIR/secrets/git/profiles.json"
  [ -f "$file" ] && command -v node >/dev/null 2>&1 || return 1
  node -e '
    const m = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))
    const rows = []
    const one = (a, where) => {
      if (!a || typeof a !== "object") return
      rows.push(`${a.provider ?? "?"}/${a.auth ?? "?"}${where ? ` @ ${where}` : ""}`)
    }
    one(m.default, "")
    for (const [host, a] of Object.entries(m.hosts ?? {})) one(a, host)
    for (const [name, a] of Object.entries(m.projects ?? {})) one(a, `workspace ${name}`)
    if (rows.length === 0) process.exit(1)
    process.stdout.write(`${rows.length} account(s): ${rows.join(", ")}`)
  ' "$file" 2>/dev/null
}

# Write (or merge) the manifest. A manifest copied from GIT_PROFILES_FILE wins
# outright: that is the unattended path for several accounts.
write_git_manifest() {
  local file="$DIR/secrets/git/profiles.json" owner args=()
  if [ -n "$GIT_PROFILES_FILE" ]; then
    [ -f "$GIT_PROFILES_FILE" ] || die "GIT_PROFILES_FILE not found: $GIT_PROFILES_FILE"
    command -v node >/dev/null 2>&1 || die "node is required to validate GIT_PROFILES_FILE"
    node -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))' "$GIT_PROFILES_FILE" 2>/dev/null \
      || die "GIT_PROFILES_FILE is not valid JSON: $GIT_PROFILES_FILE"
    mkdir -p "$DIR/secrets/git" && chmod 700 "$DIR/secrets/git" 2>/dev/null || true
    cp "$GIT_PROFILES_FILE" "$file" || die "cannot write $file"
    chmod 600 "$file" 2>/dev/null || true
    log "git repository access: manifest copied from $GIT_PROFILES_FILE"
  elif [ -n "$GIT_ENTRIES_JSON" ]; then
    command -v node >/dev/null 2>&1 || die "node is required to write the git manifest"
    mkdir -p "$DIR/secrets/git" && chmod 700 "$DIR/secrets/git" 2>/dev/null || true
    args=(--file "$file")
    [ -f "$file" ] && args+=(--merge)
    if [ -n "$GIT_AUTHOR_NAME" ] && [ -n "$GIT_AUTHOR_EMAIL" ]; then
      args+=(--name "$GIT_AUTHOR_NAME" --email "$GIT_AUTHOR_EMAIL")
    fi
    printf '%s' "$GIT_ENTRIES_JSON" | node "$SRC_DIR/scripts/git-manifest.mjs" "${args[@]}" \
      || die "cannot write $file"
    log "git repository access: $file"
  else
    return 0
  fi
  owner="$SERVICE_USER:$SERVICE_USER"
  chown -R "$owner" "$DIR/secrets" 2>/dev/null || true
}

# Podman bridge traffic is not covered by ufw's default policy. Without these
# rules containers cannot resolve each other through aardvark-dns or reach the
# host gateway, so Penpot never starts. Docker used to bypass ufw; Podman does
# not. Added only when the operator chose the design stack and ufw is active.
design_ufw_apply() {
  [ "$DESIGN" = penpot ] || return 0
  command -v ufw >/dev/null 2>&1 || return 0
  ufw_state | head -1 | grep -q 'Status: active' || return 0
  [ "$(id -u)" = 0 ] || return 0
  local net iface cidr
  net="$(podman network ls --filter label=io.podman.compose.project=design --format '{{.Name}}' 2>/dev/null | head -1)"
  [ -n "$net" ] || net=design_design
  iface="$(podman network inspect "$net" --format '{{.NetworkInterface}}' 2>/dev/null || true)"
  [ -n "$iface" ] || iface=podman1
  cidr="$(lan_network "$DSH_BIND_IP")"
  local lan_if=""
  lan_if="$(ip -o route get "$DSH_BIND_IP" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
  ufw allow in on "$iface" >/dev/null 2>&1 || warn "ufw: could not allow $iface"
  ufw route allow in on "$iface" out on "$iface" >/dev/null 2>&1 || warn "ufw: could not route $iface"
  # Published container ports are DNAT'd; ufw's forward policy sees them, not
  # the INPUT rule for the published port. Allow the LAN interface into the
  # podman bridge, or remote clients time out while localhost works.
  if [ -n "$lan_if" ] && [ "$lan_if" != "$iface" ]; then
    ufw route allow in on "$lan_if" out on "$iface" >/dev/null 2>&1 \
      || warn "ufw: could not route $lan_if → $iface"
  fi
  ufw allow from "$cidr" to any port "$DSH_DESIGN_PORT" proto tcp >/dev/null 2>&1 \
    || warn "ufw: could not allow $DSH_DESIGN_PORT from $cidr"
  log "ufw: allowed the Podman bridge $iface, $lan_if → $iface and port $DSH_DESIGN_PORT from $cidr"
}

# --- firewall advisory ------------------------------------------------------
# ufw gates the systemd service through its INPUT chain. It cannot be applied
# from the runtime: the installer only warns, and /firewall (native) explains
# the rule. A rule outlives --uninstall, so it is never added silently.
#
# It warns and never acts. The installer cannot know whether a port should be
# LAN-only, VPN-only or tunnel-only, and a ufw rule outlives --uninstall.

ufw_state() {
  if [ "$(id -u)" = 0 ]; then
    ufw status 2>/dev/null
    return 0
  fi
  # -n: a --check run as a normal user must not sit waiting for a password.
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo -n ufw status 2>/dev/null
    return 0
  fi
  # Unprivileged without passwordless sudo (the usual `./install.sh --check`).
  # The rules are root-only, but the enable flag is world-readable, so a check
  # can still say "your firewall is on" instead of going silent.
  if [ -r /etc/ufw/ufw.conf ] && grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
    printf 'Status: active\n'
    return 0
  fi
  return 1
}

# Whether the rules themselves are readable: a hint without them cannot claim
# a port is closed, only that ufw is on.
ufw_rules_readable() {
  [ "$(id -u)" = 0 ] && return 0
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null
}

# The network ufw wants ("allow from 10.0.0.0/8"), derived from the bind
# address so the hint is copy-pasteable instead of a /16 guess.
lan_network() {
  local addr="$1" cidr="" prefix a b c d num mask net
  if command -v ip >/dev/null 2>&1; then
    cidr="$(ip -o -4 addr show scope global 2>/dev/null \
      | awk -v ip="$addr" '$4 ~ "^" ip "/" { print $4; exit }')"
  fi
  # Without an interface carrying the bind address (a --check on another host,
  # or a stale .env), assume a /24 and still print the network, not the host.
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
# allow. Silent when ufw is absent or inactive: a host where the operator did
# nothing about firewalling gets nothing from us.
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

random_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  elif command -v node >/dev/null 2>&1; then
    node -e 'process.stdout.write(require("node:crypto").randomBytes(24).toString("hex"))'
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

provider_key_env() {
  case "$1" in
    opencode-go) printf %s OPENCODE_GO_API_KEY ;;
    deepseek-official) printf %s DEEPSEEK_API_KEY ;;
    *) printf %s DSH_PROVIDER_API_KEY ;;
  esac
}

# CPUs systemd's CPUQuota is measured against: 100% is one core, so a share of
# the machine is percent * cores.
cpu_count() {
  nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
}

# Re-running must keep what the deployment already answered; only fill blanks.
# The provider key is read after the loop: it belongs to whichever provider the
# file names, and a repair must never ask for it again (a second answer is how a
# working deployment ends up with two keys and no way to tell which one is live).
read_existing_env() {
  local key value provider key_var
  [ -r "$DIR/.env" ] || return 0
  for key in DSH_PORT DSH_BIND_IP DSH_PUBLIC_URL DSH_PROVIDER DSH_MODEL DSH_RESOURCE_PERCENT DSH_TELEGRAM_BOT_TOKEN \
             ALLOWED_USER_IDS DSH_ADMIN_USER_ID DSH_UPDATER_TOKEN DESIGN DSH_DESIGN_PORT CONTAINERS \
             DSH_TELEGRAM_PUBLISHER_TOKENS GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_PROVIDER GIT_TOKEN \
             DSH_PROVIDER_API_KEY_ENV; do
    # The last assignment is what the runtime reads (systemd's EnvironmentFile
    # and Node's .env loader agree), so the installer agrees too.
    value="$(sed -n "s/^${key}=//p" "$DIR/.env" | tail -1)"
    if [ -n "${!key:-}" ]; then
      # DESIGN/CONTAINERS are structural: an inherited environment value (the
      # agent's shell carries the service env) must not disable a deployed
      # Penpot stack. Only an explicit flag or config file may change them.
      if { [ "$key" = DESIGN ] && [ "$DESIGN_SET" != 1 ]; } \
         || { [ "$key" = CONTAINERS ] && [ "$CONTAINERS_SET" != 1 ]; }; then
        if [ -n "$value" ]; then printf -v "$key" '%s' "$value"; fi
        continue
      fi
      # An explicit flag/config already decided; do not warn about the
      # environment variable it replaced.
      if { [ "$key" = DESIGN ] && [ "$DESIGN_SET" = 1 ]; } \
         || { [ "$key" = CONTAINERS ] && [ "$CONTAINERS_SET" = 1 ]; }; then
        continue
      fi
      # An exported variable silently winning over the deployed value is how a
      # repair run rewrites a working allowlist by accident.
      if [ -n "$value" ] && [ "${!key}" != "$value" ]; then
        warn "$key is set in the environment and overrides the deployed value in $DIR/.env"
      fi
      continue
    fi
    if [ -n "$value" ]; then printf -v "$key" '%s' "$value"; fi
  done
  provider="${DSH_PROVIDER:-}"
  [ -n "$provider" ] || provider="$(sed -n 's/^DSH_PROVIDER=//p' "$DIR/.env" | tail -1)"
  [ -n "$provider" ] || provider=opencode-go
  key_var="${DSH_PROVIDER_API_KEY_ENV:-}"
  [ -n "$key_var" ] || key_var="$(provider_key_env "$provider")"
  DEPLOYED_KEY="$(sed -n "s/^${key_var}=//p" "$DIR/.env" | tail -1)"
  DEPLOYED_KEY_ENV="$key_var"
  return 0
}

# --- uninstall -------------------------------------------------------------
# Removing a deployment is a first-class operation: stopping a stray runtime by
# hand is how a second poller survives. Data is kept unless --purge is passed,
# and the checkout is never deleted — the last line says what to remove.
uninstall_plan() {
  printf '    directory: %s\n' "$DIR"
  printf '    removes:   dsh.service, dsh-updater.service and the /usr/local/bin launchers\n'
  if [ "$PURGE" = 1 ]; then
    printf '    deletes:   %s/data, %s/.env, %s/backups\n' "$DIR" "$DIR" "$DIR"
  else
    printf '    keeps:     %s/data, %s/.env, %s/backups (pass --purge to delete them)\n' "$DIR" "$DIR" "$DIR"
  fi
}

uninstall_run() {
  if [ -f /etc/systemd/system/dsh.service ]; then
      log "stopping and disabling the systemd units"
      run systemctl disable --now dsh-updater.service 2>/dev/null || true
      run systemctl disable --now dsh.service 2>/dev/null || true
      run rm -f /etc/systemd/system/dsh.service /etc/systemd/system/dsh-updater.service
      run systemctl daemon-reload
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
  log "uninstalled"
  if [ "$PURGE" != 1 ]; then
    printf '    kept:    %s/data, %s/.env, %s/backups\n' "$DIR" "$DIR" "$DIR"
  fi
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    printf '    user:    %s still exists (userdel -r %s if it owns nothing else)\n' "$SERVICE_USER" "$SERVICE_USER"
  fi
  printf '    dir:     %s still exists (rm -rf %s to remove the checkout)\n' "$DIR" "$DIR"
}

podman_ready() {
  command -v podman >/dev/null 2>&1
}

podman_compose_ready() {
  command -v podman-compose >/dev/null 2>&1
}

node_ready() {
  command -v node >/dev/null 2>&1 && [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -ge 22 ]
}

# --- root, before the questions --------------------------------------------
# Installing the systemd units needs root. Re-running here, before the first
# question, is the difference between answering once and answering twice — and
# `</dev/tty` keeps the prompts working when this script arrived through a
# pipe.
rerun_as_root() {
  log "this install needs root — re-running with sudo"
  # -E is refused by some sudoers policies (Ubuntu prints "preserving the entire
  # environment is not supported"); pass the answers explicitly instead.
  local -a keep=() pair
  while IFS= read -r pair; do
    case "$pair" in
      DSH_*=*|PROVIDER_KEY=*|ALLOWED_USER_IDS=*|SERVICE_USER=*|CONTAINERS=*|DESIGN=*) keep+=("$pair") ;;
    esac
  done < <(env 2>/dev/null || true)
  # Remember where the download lives, so the installer can say it is not the
  # deployment once it has one of its own.
  exec sudo env "${keep[@]}" DSH_BOOTSTRAP_SOURCE="$SRC_DIR" bash "$SRC_DIR/install.sh" "$@" </dev/tty
}

if [ "$CHECK" = 0 ] && [ "$UNINSTALL" = 0 ] && [ "$DOCTOR" = 0 ] && [ "$(id -u)" != 0 ]; then
  if command -v sudo >/dev/null 2>&1; then rerun_as_root; fi
  die "this installs a systemd service — run with sudo"
fi

case "${DESIGN:-}" in
  ""|none|penpot) ;;
  # Migration: the old value meant the Docker stack, which no longer exists.
  docker) DESIGN=penpot; warn "DESIGN=docker is now DESIGN=penpot (Podman); the stack will be recreated" ;;
  *) die "--design must be penpot or none" ;;
esac
case "${CONTAINERS:-}" in
  ""|podman|none) ;;
  *) die "--containers must be podman or none" ;;
esac
[ -n "$CONTAINERS" ] || CONTAINERS=podman
[ -n "$DESIGN" ] || DESIGN=none
# Penpot runs on Podman in this setup; asking for it implies the runtime.
if [ "$DESIGN" = penpot ] && [ "$CONTAINERS" = none ]; then
  CONTAINERS=podman
  warn "--design penpot needs Podman; containers set to podman"
fi
[ -n "$DIR" ] || DIR=/srv/dsh

read_existing_env

# --- deployment path guard -------------------------------------------------
# --purge deletes data/ and .env as root. Refuse anything that is not a
# deployment, and never let a typo in --dir turn into `rm -rf /data`.
resolved_dir() {
  realpath -m -- "$1" 2>/dev/null || printf '%s\n' "$1"
}

assert_safe_dir() {
  local dir="$1" resolved
  resolved="$(resolved_dir "$dir")"
  case "$resolved" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "refusing --dir $resolved — choose the deployment directory, not a system path" ;;
  esac
  case "$resolved" in
    /*/*) ;;
    *) die "--dir must be an absolute path below / (got $resolved)" ;;
  esac
  if [ "$resolved" = "${HOME:-/nonexistent}" ]; then
    die "refusing to use $HOME itself as --dir"
  fi
  printf '%s\n' "$resolved"
}

assert_deployment_dir() {
  local resolved
  resolved="$(assert_safe_dir "$1")"
  if [ ! -f "$resolved/VERSION" ] && [ ! -f "$resolved/.env" ]; then
    die "$resolved does not look like a DSH deployment (no VERSION or .env) — nothing deleted"
  fi
  printf '%s\n' "$resolved"
}

# --- doctor ----------------------------------------------------------------
# One health check, shared with update.sh, so an install and a repair answer
# the same questions in the same words. It never installs anything and
# works on a stopped deployment; --fix repairs the safe subset (duplicate .env
# keys, the provider key shadowed by a stored copy, duplicated patch blocks).
if [ "$DOCTOR" = 1 ] || [ "$FIX" = 1 ]; then
  [ -x "$SRC_DIR/scripts/repair.sh" ] || die "scripts/repair.sh is missing — run this from a release checkout"
  repair_args=(--dir "$DIR")
  [ "$FIX" = 1 ] && repair_args+=(--fix)
  exec bash "$SRC_DIR/scripts/repair.sh" "${repair_args[@]}"
fi

# Defaults apply after the existing .env, so a repair keeps the deployed values.
[ -n "$DSH_PORT" ] || DSH_PORT=4310
[ -n "$DESIGN" ] || DESIGN=none
[ "$DESIGN" = penpot ] && { [ -n "$DSH_DESIGN_PORT" ] || DSH_DESIGN_PORT=8090; }
[ -n "$DSH_PROVIDER" ] || DSH_PROVIDER=opencode-go

model_default() {
  case "$1" in
    opencode-go) printf %s deepseek-v4.1-flash ;;
    *) printf %s deepseek-v4-flash ;;
  esac
}

if [ "$UNINSTALL" = 1 ]; then
  DIR="$(assert_safe_dir "$DIR")"
  echo
  log "uninstall plan"
  uninstall_plan
  if [ "$CHECK" = 1 ]; then
    echo
    log "check only — nothing was changed"
    exit 0
  fi
  if [ "$(id -u)" != 0 ]; then
    die "removing the systemd units needs root — run with sudo"
  fi
  DIR="$(assert_deployment_dir "$DIR")"
  if [ "$YES" != 1 ]; then
    can_ask || die "refusing to uninstall without a terminal — add --yes to confirm"
    printf 'Type "yes" to continue: ' >&2
    answer="$(read_from_terminal)"
    [ "$answer" = yes ] || die "cancelled"
  fi
  if [ "$PURGE" = 1 ]; then
    if [ "$YES" != 1 ]; then
      printf 'Type the deployment path to delete its data (%s): ' "$DIR" >&2
      answer="$(read_from_terminal)"
      [ "$answer" = "$DIR" ] || die "path did not match — cancelled"
    fi
    backup="/var/backups/dsh-purge-$(date +%Y%m%d-%H%M%S).tgz"
    log "backing up $DIR/data to $backup before deleting it"
    run mkdir -p /var/backups
    run tar czf "$backup" -C "$DIR" data || die "backup failed — nothing was deleted"
  fi
  uninstall_run
  exit 0
fi

# --- prompts ---------------------------------------------------------------
# Required answers first. Everything else has a working default; the plan shows
# those defaults, and one "Customize" question is the only way to change them.
# A first run therefore costs four answers, not fifteen.
if [ "$CHECK" != 1 ]; then
  ask DSH_PROVIDER "Model provider (opencode-go or deepseek-official)" opencode-go
  # the model default follows the provider that was just chosen, not the
  # pre-prompt default guessed
  [ -n "$DSH_MODEL" ] || DSH_MODEL="$(model_default "$DSH_PROVIDER")"
  ask DSH_MODEL "Model" "$(model_default "$DSH_PROVIDER")"
  PROVIDER_KEY_ENV="$(provider_key_env "$DSH_PROVIDER")"
  # Keep the key the deployment already has. Asking again on every repair is
  # how one deployment ends up with two keys: the new answer lands in .env, an
  # older copy stored by the web UI keeps winning, and model calls fail with a
  # credential nobody remembers setting.
  deployed_key=""
  if [ -f "$DIR/.env" ] && [ "$(sed -n 's/^DSH_PROVIDER=//p' "$DIR/.env" | tail -1)" = "$DSH_PROVIDER" ]; then
    deployed_key="$(sed -n "s/^${PROVIDER_KEY_ENV}=//p" "$DIR/.env" | tail -1)"
  fi
  if [ -n "${PROVIDER_KEY:-}" ]; then
    : # an explicit answer (environment or --config) always wins
  elif [ -n "$deployed_key" ] && [ "$ROTATE_KEY" != 1 ]; then
    PROVIDER_KEY="$deployed_key"
    PROVIDER_KEY_KEPT=1
  else
    ask_secret PROVIDER_KEY "$PROVIDER_KEY_ENV (blank = keep the deployed key)" ""
  fi
  ask_secret DSH_TELEGRAM_BOT_TOKEN "Telegram bot token"
  if [ -n "$DSH_TELEGRAM_BOT_TOKEN" ]; then
    ask ALLOWED_USER_IDS "Allowed Telegram user ids (comma separated)" ""
    # Access and administration are separate questions: everyone allowed may use
    # the agent, one account may update or roll back the deployment.
    first_allowed="$(printf %s "${ALLOWED_USER_IDS%%,*}" | tr -d " ")"
    [ -n "$DSH_ADMIN_USER_ID" ] || DSH_ADMIN_USER_ID="$first_allowed"
  fi
fi

# Defaults for everything the quick path did not ask. They are what the plan
# prints; Customize replaces them one by one.
[ -n "$DSH_PORT" ] || DSH_PORT=4310
[ -n "$DSH_BIND_IP" ] || DSH_BIND_IP="$(detect_lan_ip)"
[ -n "$DSH_PROVIDER" ] || DSH_PROVIDER=opencode-go
[ -n "$DSH_MODEL" ] || DSH_MODEL="$(model_default "$DSH_PROVIDER")"
# Access and administration are separate answers, but a quick/unattended run
# still needs an admin: the first allowed id is the safe default.
if [ -z "$DSH_ADMIN_USER_ID" ] && [ -n "$ALLOWED_USER_IDS" ]; then
  DSH_ADMIN_USER_ID="$(printf %s "${ALLOWED_USER_IDS%%,*}" | tr -d ' ')"
fi
[ -n "$DSH_RESOURCE_PERCENT" ] || DSH_RESOURCE_PERCENT=30
[ -n "$CONTAINERS" ] || CONTAINERS=podman
[ -n "$DESIGN" ] || DESIGN=none
if [ "$DESIGN" = penpot ]; then
  [ -n "$DSH_DESIGN_PORT" ] || DSH_DESIGN_PORT=8090
  [ "$CONTAINERS" = none ] && CONTAINERS=podman
fi
case "$DSH_RESOURCE_PERCENT" in
  unlimited|Unlimited|none|None) DSH_RESOURCE_PERCENT=0 ;;
esac
case "$DSH_RESOURCE_PERCENT" in
  ''|*[!0-9]*) die "DSH_RESOURCE_PERCENT must be 0-100 (0 = unlimited)" ;;
esac
[ "$DSH_RESOURCE_PERCENT" -le 100 ] || die "DSH_RESOURCE_PERCENT must be 0-100 (0 = unlimited)"

if [ "$ROTATE_KEY" = 1 ] && [ -z "${PROVIDER_KEY:-}" ] && [ "$CHECK" != 1 ]; then
  die "--rotate-key needs a terminal (drop --yes) or PROVIDER_KEY in the environment / --config"
fi

if [ "$CHECK" != 1 ] && [ -z "$DSH_UPDATER_TOKEN" ]; then
  DSH_UPDATER_TOKEN="$(random_token)"
  log "generated an updater token (stored in the deployment .env)"
fi

DATA_HOME="$DIR/data/home"
DATA_WORKSPACE="$DIR/data/workspace"
SUPERVISOR_STATE="$DIR/data/supervisor"
UPDATER_URL="http://127.0.0.1:8787"
[ -n "$REF" ] || REF="v$SETUP_VERSION"

# Reaching here as non-root means --check, or a sudo that was refused: the
# re-exec above normally handles it.
[ "$CHECK" != 1 ] && [ "$(id -u)" != 0 ] \
  && die "this installs a systemd service — run with sudo"

compute_deps_plan() {
  PODMAN_REQUIRED=0
  [ "$CONTAINERS" = podman ] && PODMAN_REQUIRED=1
  if [ "$DEPS" = 0 ]; then
    DEPS_PLAN="skipped (--no-deps)"
    return 0
  fi
  DEPS_PLAN=""
  if command -v git >/dev/null 2>&1; then DEPS_PLAN="git present"; else DEPS_PLAN="installs git"; fi
  if [ "$PODMAN_REQUIRED" = 1 ]; then
    if podman_ready && { [ "$DESIGN" != penpot ] || podman_compose_ready; }; then
      DEPS_PLAN="$DEPS_PLAN · podman present"
    elif [ "$DESIGN" = penpot ]; then
      DEPS_PLAN="$DEPS_PLAN · installs podman + podman-compose (needs root)"
    else
      DEPS_PLAN="$DEPS_PLAN · installs podman (needs root)"
    fi
  else
    DEPS_PLAN="$DEPS_PLAN · podman not requested"
  fi
  if node_ready; then DEPS_PLAN="$DEPS_PLAN · node present"; else DEPS_PLAN="$DEPS_PLAN · installs Node 22 (NodeSource)"; fi
}

warn_exposure() {
  if [ "$DSH_BIND_IP" != "127.0.0.1" ] && [ "$DSH_BIND_IP" != "localhost" ]; then
    echo
    warn "the web UI on http://$DSH_BIND_IP:$DSH_PORT/ is protected only by a sign-in"
    warn "  token printed in the startup log. Anyone who can read that log, or follow the"
    warn "  link, drives this agent and runs tools on this host as ${SERVICE_USER:-dsh}."
    warn "  Keep it on a trusted network, or bind 127.0.0.1 and tunnel with:"
    warn "  ssh -L $DSH_PORT:127.0.0.1:$DSH_PORT <user>@<host>"
  fi
}

print_plan() {
  echo
  log "plan"
  printf '    directory: %s\n' "$DIR"
  printf '    version:   %s (DSH %s)\n' "$SETUP_VERSION" "$DSH_VERSION"
  printf '    web:       http://%s:%s/\n' "$DSH_BIND_IP" "$DSH_PORT"
  printf '    provider:  %s / %s\n' "$DSH_PROVIDER" "$DSH_MODEL"
  printf '    telegram:  %s\n' "$([ -n "$DSH_TELEGRAM_BOT_TOKEN" ] && echo configured || echo disabled)"
  if [ -n "$DSH_TELEGRAM_BOT_TOKEN" ]; then
    printf '    bots:      main%s\n' "$(printf '%s' "$DSH_TELEGRAM_PUBLISHER_TOKENS" | tr ',' '\n' | grep -c . | awk '$1 > 0 { printf " + %d publisher(s)", $1 }')"
  fi
  if [ -n "$DSH_ADMIN_USER_ID" ]; then
    printf '    admin:     %s (may update, restart and roll back)\n' "$DSH_ADMIN_USER_ID"
  fi
  if [ "$DESIGN" = penpot ]; then
    printf '    design:    Penpot on http://%s:%s/ (Podman)\n' "$DSH_BIND_IP" "$DSH_DESIGN_PORT"
  else
    printf '    design:    none (re-run with --design penpot to add it later)\n'
  fi
  printf '    containers: %s\n' "$(if [ "$CONTAINERS" = podman ]; then printf 'podman (rootless)'; else printf 'none'; fi)"
  printf '    user:      %s\n' "$SERVICE_USER"
  printf '    data:      %s\n' "$DATA_HOME"
  printf '    updater:   %s (127.0.0.1 only, root)\n' "$UPDATER_URL"
  if [ "$DSH_RESOURCE_PERCENT" = 0 ]; then
    printf '    resources: unlimited\n'
  else
    printf '    resources: %s%% of this machine (memory %s%%, cpu %s%% of %s cores)\n' \
      "$DSH_RESOURCE_PERCENT" "$DSH_RESOURCE_PERCENT" \
      "$((DSH_RESOURCE_PERCENT * $(cpu_count)))" "$(cpu_count)"
  fi
  printf '    deps:      %s\n' "$DEPS_PLAN"
  if [ -n "$GIT_AUTHOR_NAME" ]; then
    printf '    git:       %s <%s>\n' "$GIT_AUTHOR_NAME" "${GIT_AUTHOR_EMAIL:-no email}"
  else
    printf '    git:       no author — commits from a workspace will fail until set\n'
  fi
  if [ -n "$GIT_PROVIDER" ] && [ -n "$GIT_TOKEN" ]; then
    printf '    git auth:  %s%s (token stored in %s/secrets/git)\n' "$GIT_PROVIDER" \
      "${GIT_HOST:+ ($GIT_HOST)}" "$DIR"
  elif manifest_summary="$(git_manifest_summary)"; then
    printf '    git auth:  %s (deployed manifest kept)\n' "$manifest_summary"
  else
    printf '    git auth:  none — the agent can read public repositories only\n'
  fi
  printf '    writes:    %s/.env, the systemd units, /usr/local/bin launchers, the profile\n' "$DIR"
  printf '    keeps:     %s/data, %s/backups, %s/secrets\n' "$DIR" "$DIR" "$DIR"
}

# A deployment that already exists gets its health report first: "what would a
# repair change?" is only answerable together with "what is wrong right now?".
if [ -f "$DIR/.env" ] && [ -x "$SRC_DIR/scripts/repair.sh" ]; then
  echo
  log "existing deployment"
  bash "$SRC_DIR/scripts/repair.sh" --dir "$DIR" || true
fi

compute_deps_plan
print_plan

if [ "$CHECK" = 1 ]; then
  warn_exposure
  # Native mode only: a published Docker port never reaches ufw's INPUT chain.
  ufw_hints "$DSH_PORT" "$DSH_BIND_IP"
  echo
  log "check only — nothing was changed"
  exit 0
fi

# Offer the advanced answers only after the plan shows what the defaults mean.
CUSTOMIZE=0
if can_ask; then
  printf 'Customize port, address, resources, containers, design or git? [y/N] ' >&2
  answer="$(read_from_terminal)"
  case "$answer" in
    y|Y|yes|Yes) CUSTOMIZE=1 ;;
  esac
fi
if [ "$CUSTOMIZE" = 1 ]; then
  ask DSH_PORT "Web UI port" 4310
  ask DSH_BIND_IP "Web UI address: your LAN IP (phone/browser access) or 127.0.0.1 (host only)" "$(detect_lan_ip)"
  if [ -n "$DSH_TELEGRAM_BOT_TOKEN" ]; then
    ask DSH_ADMIN_USER_ID "Admin user id (may update/restart/roll back)" "${DSH_ADMIN_USER_ID:-${first_allowed:-}}"
    # One bot has one budget: ~20 messages/minute per group, shared by every
    # topic. Extra bots multiply it, and each must be a member of the group.
    ask_secret_keep DSH_TELEGRAM_PUBLISHER_TOKENS \
      "Extra publisher bot tokens to raise the rate limit (comma separated)"
  fi
  # The agent commits; a commit without an author fails. A repair must keep the
  # identity the agent already commits as: the deployed .gitconfig wins over the
  # invoking user's global one, so re-running under sudo does not silently
  # switch the author to root. Fall back to the user who invoked sudo, not root.
  deployed_gitconfig="$DIR/data/home/.gitconfig"
  invoking_user="${SUDO_USER:-$(id -un)}"
  default_git_name="$(git config --file "$deployed_gitconfig" user.name 2>/dev/null || true)"
  default_git_email="$(git config --file "$deployed_gitconfig" user.email 2>/dev/null || true)"
  [ -n "$default_git_name" ] || default_git_name="$(git config --global user.name 2>/dev/null || true)"
  [ -n "$default_git_email" ] || default_git_email="$(git config --global user.email 2>/dev/null || true)"
  if [ -z "$default_git_name" ] && [ -n "${SUDO_USER:-}" ]; then
    default_git_name="$(sudo -u "$SUDO_USER" git config --global user.name 2>/dev/null || true)"
  fi
  if [ -z "$default_git_email" ] && [ -n "${SUDO_USER:-}" ]; then
    default_git_email="$(sudo -u "$SUDO_USER" git config --global user.email 2>/dev/null || true)"
  fi
  [ -n "$default_git_name" ] || default_git_name="$invoking_user"
  [ -n "$default_git_email" ] || default_git_email="$invoking_user@$(hostname 2>/dev/null || echo localhost)"
  ask GIT_AUTHOR_NAME "Git author name for the agent's commits (blank = skip)" "$default_git_name"
  if [ -n "$GIT_AUTHOR_NAME" ]; then
    ask GIT_AUTHOR_EMAIL "Git author email" "$default_git_email"
  fi
  # Repository access: one or more git accounts. See docs/GIT.md.
  ask_git_accounts
  ask CONTAINERS "Container runtime for the agent (podman/none)" podman
  ask DESIGN "Install the Penpot design stack? (penpot/none)" none
  if [ "$DESIGN" = penpot ]; then
    ask DSH_DESIGN_PORT "Penpot port" 8090
  fi
  ask DSH_RESOURCE_PERCENT "CPU/RAM limit for the runtime, percent of this machine (0 = unlimited)" 30
  case "$DSH_RESOURCE_PERCENT" in
    unlimited|Unlimited|none|None) DSH_RESOURCE_PERCENT=0 ;;
  esac
  case "$DSH_RESOURCE_PERCENT" in
    ''|*[!0-9]*) die "DSH_RESOURCE_PERCENT must be 0-100 (0 = unlimited)" ;;
  esac
  [ "$DSH_RESOURCE_PERCENT" -le 100 ] || die "DSH_RESOURCE_PERCENT must be 0-100 (0 = unlimited)"
  if [ "$DESIGN" = penpot ] && [ "$CONTAINERS" = none ]; then
    CONTAINERS=podman
    warn "--design penpot needs Podman; containers set to podman"
  fi
  if [ "$DESIGN" = penpot ]; then
    [ -n "$DSH_DESIGN_PORT" ] || DSH_DESIGN_PORT=8090
  fi
  compute_deps_plan
  print_plan
fi

warn_exposure
# Native mode only: a published Docker port never reaches ufw's INPUT chain.
ufw_hints "$DSH_PORT" "$DSH_BIND_IP"

# One confirmation for everything the plan above describes, so apt and the unit
# work do not start while someone is still reading it.
if can_ask; then
  printf 'Proceed? [Y/n] ' >&2
  answer="$(read_from_terminal)"
  case "$answer" in
    n|N|no|No|NO) log "cancelled — nothing was changed"; exit 1 ;;
  esac
fi

# --- dependencies ----------------------------------------------------------
# apt, only for what the chosen mode actually needs, and only when it is missing.
# --no-deps turns this into a check.
as_root() {
  if [ "$(id -u)" = 0 ]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  else die "installing packages needs root — re-run with sudo, or pass --no-deps"
  fi
}

apt_install() {
  command -v apt-get >/dev/null 2>&1 \
    || die "this is not a Debian/Ubuntu host — install $* yourself, or pass --no-deps"
  log "installing $*"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt-get update failed; trying anyway"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@"
}

ensure_podman() {
  if ! podman_ready; then
    [ "$DEPS" = 1 ] || die "podman is missing and --no-deps was given"
    apt_install podman || die "could not install podman"
  fi
  # Rootless helpers; best effort because the distro names vary.
  apt_install uidmap slirp4netns fuse-overlayfs netavark aardvark-dns \
    || warn "some podman helpers are missing (DNS needs aardvark-dns); check 'podman info'"
  # Podman 5 defaults rootless networking to pasta; without it a run fails with
  # "could not find pasta, the network namespace can't be configured".
  apt_install passt || warn "passt/pasta is missing — rootless podman cannot configure its network namespace"
  # Only the Penpot stack needs compose; the agent's `podman run` does not.
  if [ "$DESIGN" = penpot ] && ! podman_compose_ready; then
    [ "$DEPS" = 1 ] || die "podman-compose is missing and --no-deps was given"
    apt_install podman-compose || die "could not install podman-compose (Penpot uses it)"
  fi
  log "podman ready: $(podman --version)"
}

# The agent runs containers rootless as the service user. Rootless Podman needs
# a subordinate id range and a private runtime directory; both are per-user and
# only possible after the service user exists.
podman_user_setup() {
  [ "$CONTAINERS" = podman ] || return 0
  id "$SERVICE_USER" >/dev/null 2>&1 || return 0
  if ! grep -q "^$SERVICE_USER:" /etc/subuid 2>/dev/null; then
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$SERVICE_USER" \
      || warn "could not add subuid/subgid for $SERVICE_USER; rootless podman may fail"
  fi
  local uid runtime
  uid="$(id -u "$SERVICE_USER" 2>/dev/null || true)"
  runtime="/run/user/$uid"
  run mkdir -p "$DATA_HOME/.config"
  run chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_HOME/.config"
  # A user manager gives rootless Podman its systemd cgroup and removes the
  # "no systemd user session" warnings; it survives without a login.
  if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "$SERVICE_USER" 2>/dev/null \
      && log "enabled lingering for $SERVICE_USER (rootless podman cgroup)" \
      || warn "could not enable lingering for $SERVICE_USER; rootless podman falls back to cgroupfs"
  fi
  if run runuser -u "$SERVICE_USER" -- env HOME="$DATA_HOME" XDG_RUNTIME_DIR="$runtime" podman info >/dev/null 2>&1; then
    log "podman ready for $SERVICE_USER (rootless)"
  else
    warn "rootless podman is not usable as $SERVICE_USER yet — check /etc/subuid, uidmap, and re-login"
    if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = 1 ]; then
      warn "Ubuntu restricts unprivileged user namespaces (AppArmor). Either load the podman profile"
      warn "or set kernel.apparmor_restrict_unprivileged_userns=0, then re-login."
    fi
  fi
}

ensure_node() {
  if node_ready; then return 0; fi
  [ "$DEPS" = 1 ] || die "Node 22+ is missing and --no-deps was given"
  log "adding the NodeSource repository for Node 22"
  command -v curl >/dev/null 2>&1 || apt_install curl
  curl -fsSL https://deb.nodesource.com/setup_22.x | as_root bash - \
    || die "cannot add the NodeSource repository — install Node 22 yourself, or pass --no-deps"
  apt_install nodejs || die "could not install nodejs from NodeSource"
  node_ready || die "node is still older than 22 — install Node 22 yourself, or pass --no-deps"
  log "node ready: $(node --version)"
}

ensure_git() {
  if command -v git >/dev/null 2>&1; then return 0; fi
  [ "$DEPS" = 1 ] || die "git is missing and --no-deps was given"
  apt_install git || die "could not install git"
  command -v git >/dev/null 2>&1 || die "git is still missing after the install"
  log "git ready: $(git --version)"
}

if [ "$DEPS" = 1 ]; then
  # The agent commits through git in both modes, so it is not optional and not
  # worth a question.
  ensure_git
  ensure_node
  if [ "$PODMAN_REQUIRED" = 1 ]; then
    ensure_podman
  fi
fi

# --- git: identity and repository access ------------------------------------
# The identity goes into the runtime's own home, because that is the user that
# commits: <dir>/data/home.
write_git_identity() {
  [ -n "$GIT_AUTHOR_NAME" ] && [ -n "$GIT_AUTHOR_EMAIL" ] || return 0
  local file="$DATA_HOME/.gitconfig"
  mkdir -p "$DATA_HOME"
  git config --file "$file" user.name "$GIT_AUTHOR_NAME" || return 0
  git config --file "$file" user.email "$GIT_AUTHOR_EMAIL" || return 0
  git config --file "$file" init.defaultBranch main || true
  chown "$SERVICE_USER:$SERVICE_USER" "$file" 2>/dev/null || true
  log "git identity: $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>"
}

# --- shared: write the deployment .env -------------------------------------
set_env() {
  local key="$1" value="$2" file="$3" tmp owner="" mode=""
  tmp="$(mktemp)"
  if [ -f "$file" ]; then
    owner="$(stat -c '%u:%g' "$file" 2>/dev/null || true)"
    mode="$(stat -c '%a' "$file" 2>/dev/null || true)"
    grep -v "^${key}=" "$file" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  # A rewrite must not turn .env into root:root 0600: the service reads it
  # through systemd, but the doctor and the operator need the deployed mode.
  [ -z "$owner" ] || chown "$owner" "$tmp" 2>/dev/null || true
  [ -z "$mode" ] || chmod "$mode" "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
}

# Drop every assignment of one key. Used when a provider route changes hands: an
# old key left beside the new one is what makes "which key is live?" unanswerable.
del_env() {
  local key="$1" file="$2" tmp
  [ -f "$file" ] || return 0
  grep -q "^${key}=" "$file" || return 0
  tmp="$(mktemp)"
  grep -v "^${key}=" "$file" > "$tmp" || true
  mv "$tmp" "$file"
}

# The runtime resolves a stored credential before the environment, so a key
# saved once through the web UI outranks every .env the installer writes. Make
# the deployment key win where that file already exists; a missing file is left
# missing (the environment is then the only source, which is what a first
# install wants, and creating it as root would lock the runtime out).
sync_stored_credential() {
  local file="$1" home="$DATA_HOME" store="$DATA_HOME/.credentials.yaml"
  local key_var key owner state
  [ -f "$store" ] || return 0
  [ -f "$SRC_DIR/scripts/credentials.mjs" ] || return 0
  key_var="${PROVIDER_KEY_ENV:-$(provider_key_env "$DSH_PROVIDER")}"
  key="$(sed -n "s/^${key_var}=//p" "$file" | tail -1)"
  command -v node >/dev/null 2>&1 || {
    warn "cannot reconcile $store without node; save $key_var in Settings -> Models to match .env"
    return 0
  }
  if [ -z "$key" ]; then
    state="$(DSH_VALUE= node "$SRC_DIR/scripts/credentials.mjs" status --home "$home" --ref "$key_var" 2>/dev/null || true)"
    case "$state" in
      ""|absent) ;;
      *) warn "$key_var is stored by the web UI but not in $file — the stored key is what model calls use" ;;
    esac
    return 0
  fi
  state="$(DSH_VALUE="$key" node "$SRC_DIR/scripts/credentials.mjs" status --home "$home" --ref "$key_var" 2>/dev/null || true)"
  case "$state" in
    ""|absent|match) return 0 ;;
  esac
  if DSH_VALUE="$key" node "$SRC_DIR/scripts/credentials.mjs" sync --home "$home" --ref "$key_var" >/dev/null 2>&1; then
    owner="$SERVICE_USER:$SERVICE_USER"
    chown "$owner" "$store" "$store.bak" 2>/dev/null || true
    log "reconciled the stored $key_var with $file (backup: $store.bak)"
  else
    warn "could not reconcile $store; save $key_var in Settings -> Models or remove the file"
  fi
}

write_env() {
  local file="$1"
  [ -f "$file" ] || : > "$file"
  # Values that belonged to the removed container deployment: drop them so a
  # repaired .env describes one deployment shape only.
  del_env MODE "$file"
  del_env DSH_UID "$file"
  del_env DSH_GID "$file"
  del_env DSH_DOCKER_GID "$file"
  del_env DSH_MEM_LIMIT "$file"
  del_env DSH_CPUS "$file"
  set_env DSH_PORT "$DSH_PORT" "$file"
  set_env DSH_BIND_IP "$DSH_BIND_IP" "$file"
  if [ -n "$DSH_PUBLIC_URL" ]; then
    set_env DSH_PUBLIC_URL "$DSH_PUBLIC_URL" "$file"
  else
    del_env DSH_PUBLIC_URL "$file"
  fi
  set_env DSH_PROVIDER "$DSH_PROVIDER" "$file"
  set_env DSH_MODEL "$DSH_MODEL" "$file"
  set_env DSH_RESOURCE_PERCENT "$DSH_RESOURCE_PERCENT" "$file"
  PROVIDER_KEY_ENV="${PROVIDER_KEY_ENV:-$(provider_key_env "$DSH_PROVIDER")}"
  if [ -n "${PROVIDER_KEY:-}" ]; then
    # One route, one key variable: switching provider drops the other key, so a
    # stale credential can never be mistaken for the live one.
    local other
    for other in OPENCODE_GO_API_KEY DEEPSEEK_API_KEY DSH_PROVIDER_API_KEY; do
      [ "$other" = "$PROVIDER_KEY_ENV" ] && continue
      del_env "$other" "$file"
    done
    set_env "$PROVIDER_KEY_ENV" "$PROVIDER_KEY" "$file"
  fi
  set_env DSH_TELEGRAM_BOT_TOKEN "$DSH_TELEGRAM_BOT_TOKEN" "$file"
  set_env ALLOWED_USER_IDS "$ALLOWED_USER_IDS" "$file"
  set_env DSH_ADMIN_USER_ID "$DSH_ADMIN_USER_ID" "$file"
  set_env DSH_TELEGRAM_PUBLISHER_TOKENS "$DSH_TELEGRAM_PUBLISHER_TOKENS" "$file"
  set_env DSH_UPDATER_TOKEN "$DSH_UPDATER_TOKEN" "$file"
  set_env DSH_SETUP_VERSION "$SETUP_VERSION" "$file"
  set_env DESIGN "$DESIGN" "$file"
  set_env CONTAINERS "$CONTAINERS" "$file"
  if [ "$DESIGN" = penpot ]; then
    set_env DSH_DESIGN_PORT "$DSH_DESIGN_PORT" "$file"
    set_env DSH_DESIGN_ENABLED 1 "$file"
    set_env PENPOT_ENABLED 1 "$file"
    local comp="$DIR/components.json"
    [ -f "$comp" ] || comp="$SRC_DIR/components.json"
    local plugin_ref=""
    [ -f "$comp" ] && plugin_ref="$(node -e 'process.stdout.write(require(process.argv[1]).components.design.plugin.ref)' "$comp" 2>/dev/null || true)"
    if [ -n "$plugin_ref" ]; then set_env PENPOT_PLUGIN_REF "$plugin_ref" "$file"; fi
    set_env PENPOT_API_URL "http://$DSH_BIND_IP:$DSH_DESIGN_PORT" "$file"
  else
    set_env DSH_DESIGN_ENABLED 0 "$file"
    set_env PENPOT_ENABLED 0 "$file"
  fi
  set_env DSH_UPDATER_URL "$UPDATER_URL" "$file"
  chmod 600 "$file"
  sync_stored_credential "$file"
}

# The signed URL the runtime prints on boot. The bare origin answers 401; this is
# the link a browser can actually use, and a restart mints a new one. Read it
# from the runtime's own log so a fresh install ends with something clickable.
web_url() {
  local logs
  logs="$(journalctl -u dsh.service --no-pager -o cat 2>/dev/null || true)"
  printf '%s\n' "$logs" | grep -oE 'https?://[^[:space:]]*[?&]token=[^[:space:]]*' | tail -1
}

wait_health() {
  local timeout="${1:-180}"
  local deadline=$((SECONDS + timeout)) i last_report=-10
  for ((i = 0; i < timeout; i += 2)); do
    if DSH_PORT="$DSH_PORT" "$SRC_DIR/healthcheck.sh" >/dev/null 2>&1; then return 0; fi
    [ "$SECONDS" -ge "$deadline" ] && break
    if [ $((i - last_report)) -ge 10 ]; then
      printf '    waiting for dsh on http://%s:%s/ (%ss/%ss)…\n' \
        "${DSH_BIND_IP:-unknown}" "${DSH_PORT:-4310}" "$i" "$timeout" >&2
      last_report=$i
    fi
    sleep 2
  done
  return 1
}

# Optional Penpot stack. It runs on rootful Podman (the updater's user), while
# the agent's own containers are rootless. Data lives in design/data and is kept
# across down/up.
design_apply() {
  [ "$DESIGN" = penpot ] || return 0
  if ! podman_ready || ! podman_compose_ready; then
    warn "the design stack needs Podman and podman-compose — the design tools stay off"
    set_env PENPOT_ENABLED 0 "$DIR/.env" 2>/dev/null || true
    set_env DSH_DESIGN_ENABLED 0 "$DIR/.env" 2>/dev/null || true
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
  set_env PENPOT_API_URL "http://$DSH_BIND_IP:$DSH_DESIGN_PORT" "$DIR/.env"
  local token
  token="$(sed -n 's/^PENPOT_ACCESS_TOKEN=//p' "$env_file" | head -1)"
  if [ -n "$token" ]; then set_env PENPOT_ACCESS_TOKEN "$token" "$DIR/.env"; fi
  # set_env preserves the mode, but a first run may have created .env here.
  chown root:"$SERVICE_USER" "$DIR/.env" 2>/dev/null || true
  chmod 640 "$DIR/.env" 2>/dev/null || true
  log "restarting the runtime so the Penpot plugin loads"
  run systemctl restart dsh.service

  # A deployment migrated from the Docker era may still have the old stack on
  # the same port and data. Stop it once; the bind-mounted data is reused.
  if command -v docker >/dev/null 2>&1 && \
     docker compose --project-directory "$dir" -f "$dir/compose.yaml" ps -q 2>/dev/null | grep -q .; then
    warn "stopping the previous Docker design stack (data is kept)"
    run docker compose --project-directory "$dir" -f "$dir/compose.yaml" down || warn "docker compose down failed"
  fi

  log "starting Penpot on Podman (the first start pulls the images)"
  ( cd "$dir" && run podman-compose -f compose.yaml up -d ) || die "podman-compose failed for the design stack"
  design_ufw_apply

  log "waiting for Penpot on http://$DSH_BIND_IP:$DSH_DESIGN_PORT/"
  local waited=0
  while [ "$waited" -lt 300 ]; do
    if curl -s -o /dev/null -m 4 -w '%{http_code}' "http://$DSH_BIND_IP:$DSH_DESIGN_PORT/" 2>/dev/null | grep -qE '200|302|303|304'; then
      break
    fi
    sleep 5; waited=$((waited + 5))
  done
  if [ "$waited" -ge 300 ]; then
    warn "Penpot did not answer within 5 minutes — inspect: (cd $dir && podman-compose ps)"
    return 1
  fi

  warn "create the first account at http://$DSH_BIND_IP:$DSH_DESIGN_PORT/ then Settings -> Access tokens,"
  warn "and put the token in $env_file as PENPOT_ACCESS_TOKEN=... to enable the design tools"
}

# A running deployment is stopped before the units are rewritten: two runtimes
# over one data directory fight over the lock, the bot token and the port.
stop_runtime() {
  if [ -f /etc/systemd/system/dsh.service ]; then
    log "stopping the running deployment"
    run systemctl disable --now dsh-updater.service 2>/dev/null || true
    run systemctl disable --now dsh.service 2>/dev/null || true
  fi
}

# --- deployment ------------------------------------------------------------
ensure_user() {
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    log "user $SERVICE_USER already exists"
    # Rootless Podman (and every tool that follows HOME) needs a home the
    # service user owns. Older installs used the root-owned checkout.
    run usermod --home "$DATA_HOME" "$SERVICE_USER" 2>/dev/null \
      || warn "could not move $SERVICE_USER's home to $DATA_HOME"
    return 0
  fi
  log "creating the unprivileged service user $SERVICE_USER"
  run useradd --system --home-dir "$DATA_HOME" --shell /bin/bash "$SERVICE_USER"
}

native_units() {
  local env_file="$DIR/.env" unit=/etc/systemd/system/dsh.service
  local node_bin node_dir service_uid
  service_uid="$(id -u "$SERVICE_USER" 2>/dev/null || echo 0)"
  node_bin="$(command -v node || echo /usr/local/bin/node)"
  node_dir="$(dirname "$node_bin")"
  # CPU/RAM share chosen at install time. MemoryMax takes a percentage of RAM;
  # CPUQuota is measured against one core, so a share of the machine is
  # percent * cores. 0 means unlimited: no lines at all.
  local limit_lines=""
  if [ "${DSH_RESOURCE_PERCENT:-0}" != 0 ]; then
    limit_lines="# CPU/RAM share chosen at install (DSH_RESOURCE_PERCENT=$DSH_RESOURCE_PERCENT; 0 = unlimited)
MemoryMax=${DSH_RESOURCE_PERCENT}%
CPUQuota=$((DSH_RESOURCE_PERCENT * $(cpu_count)))%
TasksMax=512"
  fi
  local sandbox_lines
  sandbox_lines="$(cat <<'EOF'
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
NoNewPrivileges=yes
ReadWritePaths=/srv/dsh/data /run/user/__SERVICE_UID__
# NETLINK is not a network service: `ip route`, `hostname -I` and
# getifaddrs() need it to discover the interface the runtime binds.
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
EOF
)"
  # ReadWritePaths must match the configured directory.
  sandbox_lines="${sandbox_lines//__SERVICE_UID__/$service_uid}"
  sandbox_lines="${sandbox_lines/\/srv\/dsh\/data/$DIR\/data}"

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
Environment=XDG_RUNTIME_DIR=/run/user/$service_uid
Environment=DSH_HOME=$DATA_HOME
Environment=DSH_WORKSPACE=$DATA_WORKSPACE
Environment=DSH_SUPERVISOR_STATE=$SUPERVISOR_STATE
Environment=DSH_ENTRYPOINT=/usr/local/bin/dsh-entrypoint
# Native installs keep their git manifest inside the deployment; the runtime
# reads it from there instead of /run/secrets.
Environment=DSH_GIT_SECRETS=$DIR/secrets/git
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
$limit_lines
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
Environment=DSH_UPDATER_PORT=8787
Environment=DSH_UPDATER_HOST=127.0.0.1
ExecStart=$node_bin /usr/local/bin/dsh-updater.mjs
# Always, not on-failure: after a successful apply the updater exits 0 to pick
# up the checkout it just installed, and only a restart brings it back.
Restart=always
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
  # The entrypoint runs this by absolute path. Without the link a native install
  # boots with no git credentials at all (and warns once per start).
  run ln -sf "$DIR/git-credentials.mjs" /usr/local/bin/dsh-git-credentials.mjs
  run ln -sf "$DIR/design/penpot.mjs" /usr/local/bin/penpot
}

native_apply() {
  command -v node >/dev/null 2>&1 || die "node not found — install Node >= 22.19 first"
  local node_major native_origin
  node_major="$(node -p 'process.versions.node.split(".")[0]')"
  [ "$node_major" -ge 22 ] || die "Node >= 22.19 is required (found $(node --version))"

  stop_runtime
  ensure_user
  log "creating the data layout under $DIR"
  run mkdir -p "$DATA_HOME" "$DATA_WORKSPACE" "$SUPERVISOR_STATE" "$DIR/data/.cache/tmp" "$DIR/backups"
  run chown -R "$SERVICE_USER:$SERVICE_USER" "$DIR/data"
  podman_user_setup

  if [ ! -d "$DIR/.git" ]; then
    log "initialising the setup checkout in $DIR"
    # In place: the directory already holds data/, and a clone would refuse a
    # non-empty destination.
    run mkdir -p "$DIR"
    run git -C "$DIR" init --quiet
    # Prefer the remote this checkout was cloned from: a native deployment whose
    # origin is the installer's directory can never see a new release once that
    # checkout is gone. Fall back to the local path when there is no remote.
    native_origin="$(git -C "$SRC_DIR" remote get-url origin 2>/dev/null || true)"
    [ -n "$native_origin" ] || native_origin="$SRC_DIR"
    run git -C "$DIR" remote add origin "$native_origin"
    if ! run git -C "$DIR" fetch --quiet --tags origin; then
      warn "could not fetch tags from $native_origin; using the local checkout"
      run git -C "$DIR" remote set-url origin "$SRC_DIR"
      run git -C "$DIR" fetch --quiet --tags origin
    fi
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
    run npm install -g --loglevel=error --no-fund --no-audit \
      --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs \
      "@deepseek-ai/dsh@$DSH_VERSION" pnpm@11
  elif ! command -v pnpm >/dev/null 2>&1; then
    log "installing pnpm (the Telegram adapter builds with it)"
    run npm install -g --loglevel=error --no-fund --no-audit pnpm@11
  fi

  # The unit resolves `dsh` through PATH; make sure the npm prefix is on it.
  dsh_path="$(type -P dsh 2>/dev/null || true)"
  if [ -n "$dsh_path" ] && [ "$dsh_path" != /usr/local/bin/dsh ]; then
    log "linking $dsh_path as /usr/local/bin/dsh"
    run ln -sf "$dsh_path" /usr/local/bin/dsh
  fi

  log "writing $DIR/.env"
  write_env "$DIR/.env"
  run chown root:"$SERVICE_USER" "$DIR/.env"
  run chmod 640 "$DIR/.env"
  write_git_identity
  write_git_manifest

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
    warn "no updater token — /system update setup will degrade to host instructions"
  fi

  log "waiting for health"
  if ! wait_health 180; then
    journalctl -u dsh.service --no-pager -n 40 2>/dev/null || true
    die "dsh did not become healthy. The deployment is partially applied and was not rolled back. Fix the cause above, then re-run ./install.sh — it keeps your answers and is safe to repeat. Logs: journalctl -u dsh.service -f"
  fi
  design_apply
  # The port is bound now. Say it again only if the plan did not already have:
  # the operator may have skipped the plan, e.g. --yes.
  if [ "$UFW_HINTED" = 0 ]; then ufw_hints "$DSH_PORT" "$DSH_BIND_IP"; fi
}

native_apply

echo
log "installed: $SETUP_VERSION"
signed_url="$(web_url)"
if [ -n "$signed_url" ]; then
  printf '    web:     %s\n' "$signed_url"
else
  printf '    web:     %s\n' "http://$DSH_BIND_IP:$DSH_PORT/ — the signed ?token= link is in the log (grep 'dsh web:')"
fi
if [ -n "$DSH_TELEGRAM_BOT_TOKEN" ]; then
  printf '    bot:     configured — send /web in the chat for a fresh signed link\n'
else
  printf '    bot:     not configured (web-only) — add DSH_TELEGRAM_BOT_TOKEN to %s/.env, then restart\n' "$DIR"
fi
printf '    logs:    journalctl -u dsh.service -f\n'
if [ -z "$(grep -E '^(OPENCODE_GO_API_KEY|DEEPSEEK_API_KEY)=.+' "$DIR/.env" 2>/dev/null || true)" ]; then
  printf '    key:     none yet — add %s to %s/.env, then systemctl restart dsh\n' "$(provider_key_env "$DSH_PROVIDER")" "$DIR"
fi
printf '    update:  /system update setup (Telegram) or ./update.sh --apply (host)\n'

# Self-check after every install, with the summary already printed: the two
# failures this catches ("model calls stopped working") are only confusing when
# they appear before the operator has read what was installed.
echo
if [ -x "$SRC_DIR/scripts/repair.sh" ]; then
  bash "$SRC_DIR/scripts/repair.sh" --dir "$DIR" --fix \
    || warn "the health check found something above — ./install.sh --doctor"
fi

# --- the download is not the deployment ------------------------------------
# `curl … | bash` leaves the fetched release somewhere (default ~/dsh-setup).
# Native mode copies what it needs into "$DIR" and gives it a checkout with a
# remote, so the download is scaffolding — say so instead of leaving the user
# with two directories and no way to tell which one matters.
if [ -n "${DSH_BOOTSTRAP_SOURCE:-}" ] && [ -d "$DSH_BOOTSTRAP_SOURCE" ]; then
  source_abs="$(cd "$DSH_BOOTSTRAP_SOURCE" && pwd -P)"
  dir_abs="$(cd "$DIR" && pwd -P)"
  if [ "$source_abs" != "$dir_abs" ]; then
    origin="$(git -C "$DIR" remote get-url origin 2>/dev/null || true)"
    case "$origin" in
      "$source_abs"|"$source_abs"/*)
        # The deployment updates from the download: removing it would cut
        # /system update setup off from new releases.
        printf '    note:    %s is the source this deployment updates from — keep it\n' "$source_abs"
        ;;
      *)
        printf '    note:    %s is the download, not the deployment (%s)\n' "$source_abs" "$dir_abs"
        if [ "${CLEAN_SOURCE:-0}" = 1 ]; then
          rm -rf "$source_abs" && printf '    removed: the download at %s\n' "$source_abs"
        elif can_ask; then
          printf 'Remove the download at %s? [y/N] ' "$source_abs" >&2
          source_answer="$(read_from_terminal)"
          case "$source_answer" in
            y|Y|yes|Yes) rm -rf "$source_abs" && printf '    removed: %s\n' "$source_abs" ;;
            *) printf '    keep:    rm -rf %s whenever you like\n' "$source_abs" ;;
          esac
        else
          printf '    remove:  rm -rf %s (not needed; it is not the deployment)\n' "$source_abs"
        fi
        ;;
    esac
  fi
fi
