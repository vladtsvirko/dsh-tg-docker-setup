import { readFileSync, writeFileSync } from 'node:fs'

const path = 'install.sh'
let source = readFileSync(path, 'utf8')
const edit = (from, to, label) => {
  if (!source.includes(from)) {
    console.error('missing anchor:', label)
    process.exit(1)
  }
  source = source.replace(from, to)
  console.log('patched:', label)
}

// --- dependencies: report in the plan, install after it --------------------
edit(
  `if [ "$DSH_BIND_IP" != "127.0.0.1" ] && [ "$DSH_BIND_IP" != "localhost" ]; then`,
  `printf '    deps:      %s\\\\n' "$DEPS_PLAN"

if [ "$DSH_BIND_IP" != "127.0.0.1" ] && [ "$DSH_BIND_IP" != "localhost" ]; then`,
  'plan deps line',
)

// the plan needs to know what is missing before anything runs
edit(
  `echo
log "plan"
printf '    mode:      %s\\\\n' "$MODE"`,
  `docker_ready() {
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

node_ready() {
  command -v node >/dev/null 2>&1 && [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -ge 22 ]
}

if [ "$DEPS" = 0 ]; then
  DEPS_PLAN="skipped (--no-deps)"
elif [ "$MODE" = docker ]; then
  if docker_ready; then DEPS_PLAN="docker present"; else DEPS_PLAN="installs docker.io + docker-compose-v2 (apt, needs root)"; fi
else
  if node_ready; then DEPS_PLAN="node present"; else DEPS_PLAN="installs Node 22 from NodeSource (apt, needs root)"; fi
fi

echo
log "plan"
printf '    mode:      %s\\\\n' "$MODE"`,
  'deps plan',
)

// --- install them, after the plan and before the build --------------------
edit(
  `if [ "$CHECK" = 1 ]; then
  echo
  log "check only — nothing was changed"
  exit 0
fi

# --- shared: write the deployment .env -------------------------------------`,
  `if [ "$CHECK" = 1 ]; then
  echo
  log "check only — nothing was changed"
  exit 0
fi

# --- dependencies ----------------------------------------------------------
# apt, only for what the chosen mode actually needs, and only when it is not
# already there. --no-deps turns the whole block into a check.
as_root() {
  if [ "$(id -u)" = 0 ]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  else die "installing packages needs root — re-run with sudo, or pass --no-deps"
  fi
}

apt_install() {
  command -v apt-get >/dev/null 2>&1 \\
    || die "this is not a Debian/Ubuntu host — install $* yourself, or pass --no-deps"
  log "installing $*"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt-get update failed; trying anyway"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@"
}

ensure_docker() {
  if docker_ready; then return 0; fi
  [ "$DEPS" = 1 ] || die "docker (with the compose plugin) is missing and --no-deps was given"
  if command -v docker >/dev/null 2>&1; then
    # docker is there but the compose plugin is not: that is the whole gap.
    apt_install docker-compose-v2
  else
    apt_install docker.io docker-compose-v2
  fi
  as_root systemctl enable --now docker >/dev/null 2>&1 || warn "could not start docker — start it yourself"
  # The user who ran the install keeps working without sudo after a re-login.
  if [ "$(id -u)" = 0 ] && [ -n "\${SUDO_USER:-}" ]; then
    usermod -aG docker "$SUDO_USER" 2>/dev/null && \\
      log "added $SUDO_USER to the docker group (log out and back in to use docker without sudo)"
  fi
  docker_ready || die "docker is installed but 'docker compose' still fails — check 'docker compose version'"
  log "docker ready: $(docker --version)"
}

ensure_node() {
  if node_ready; then return 0; fi
  [ "$DEPS" = 1 ] || die "Node 22+ is missing and --no-deps was given"
  log "adding the NodeSource repository for Node 22"
  command -v curl >/dev/null 2>&1 || apt_install curl
  curl -fsSL https://deb.nodesource.com/setup_22.x | as_root bash - \\
    || die "cannot add the NodeSource repository — install Node 22 yourself, or pass --no-deps"
  apt_install nodejs
  node_ready || die "node is still older than 22 — install Node 22 yourself, or pass --no-deps"
  log "node ready: $(node --version)"
}

if [ "$DEPS" = 1 ]; then
  if [ "$MODE" = docker ]; then ensure_docker; else ensure_node; fi
fi

# --- shared: write the deployment .env -------------------------------------`,
  'ensure deps',
)

writeFileSync(path, source)
console.log('install.sh: dependency installation')
