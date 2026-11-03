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

// --- quiet detached-HEAD advice from the preview clone ---------------------
edit(
  `    if ! git clone --quiet --branch "$ref" "$SETUP_REPO" "$preview"; then`,
  `    if ! git -c advice.detachedHead=false clone --quiet --branch "$ref" "$SETUP_REPO" "$preview"; then`,
  'quiet clone',
)
edit(
  `    git clone --quiet --branch "$ref" "$SETUP_REPO" "$dir" \\\\
      || die "cannot clone $SETUP_REPO at $ref"`,
  `    git -c advice.detachedHead=false clone --quiet --branch "$ref" "$SETUP_REPO" "$dir" \\\\
      || die "cannot clone $SETUP_REPO at $ref"`,
  'quiet clone 2',
)

// --- --no-deps flag --------------------------------------------------------
edit(
  `MODE="" TIER="" DIR="" CONFIG="" REF="" CHECK=0 YES=0 UNINSTALL=0 PURGE=0`,
  `MODE="" TIER="" DIR="" CONFIG="" REF="" CHECK=0 YES=0 UNINSTALL=0 PURGE=0 DEPS=1`,
  'deps default',
)
edit(
  `    --uninstall) UNINSTALL=1; shift ;;`,
  `    --no-deps) DEPS=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;`,
  'no-deps flag',
)
edit(
  `  --yes, -y              accept defaults, never prompt`,
  `  --no-deps              do not install Docker or Node; they must already exist
  --yes, -y              accept defaults, never prompt`,
  'usage no-deps',
)

// --- prompts work when the script arrives through a pipe -------------------
edit(
  `# --- prompts ---------------------------------------------------------------
ask() {
  local var="$1" prompt="$2" def="\${3:-}" current answer
  current="\${!var:-}"
  [ -n "$current" ] && def="$current"
  if [ "$YES" = 1 ] || [ "$CHECK" = 1 ] || [ ! -t 0 ]; then
    printf -v "$var" '%s' "$def"
    return 0
  fi
  printf '%s [%s]: ' "$prompt" "$def"
  read -r answer || answer=""
  printf -v "$var" '%s' "\${answer:-$def}"
}`,
  `# --- prompts ---------------------------------------------------------------
# \`wget … | bash\` leaves stdin as the script itself, so a prompt has to read the
# terminal directly or the install silently takes every default.
can_ask() {
  [ "$YES" = 1 ] && return 1
  [ "$CHECK" = 1 ] && return 1
  [ -t 0 ] && return 0
  [ -r /dev/tty ]
}

read_from_terminal() {
  local answer=""
  if [ -t 0 ]; then read -r answer || answer=""; else read -r answer </dev/tty || answer=""; fi
  printf '%s' "$answer"
}

ask() {
  local var="$1" prompt="$2" def="\${3:-}" current answer
  current="\${!var:-}"
  [ -n "$current" ] && def="$current"
  if ! can_ask; then
    printf -v "$var" '%s' "$def"
    return 0
  fi
  printf '%s [%s]: ' "$prompt" "$def"
  answer="$(read_from_terminal)"
  printf -v "$var" '%s' "\${answer:-$def}"
}`,
  'ask via tty',
)

edit(
  `ask_secret() {
  local var="$1" prompt="$2" current answer
  current="\${!var:-}"
  if [ -n "$current" ] || [ "$YES" = 1 ] || [ "$CHECK" = 1 ] || [ ! -t 0 ]; then
    [ -n "$current" ] || printf -v "$var" '%s' ''
    return 0
  fi
  printf '%s (blank = disabled): ' "$prompt"
  read -r -s answer || answer=""
  printf '\\n'
  printf -v "$var" '%s' "$answer"
}`,
  `ask_secret() {
  local var="$1" prompt="$2" current answer
  current="\${!var:-}"
  if [ -n "$current" ] || ! can_ask; then
    [ -n "$current" ] || printf -v "$var" '%s' ''
    return 0
  fi
  printf '%s (blank = disabled): ' "$prompt"
  if [ -t 0 ]; then read -r -s answer || answer=""; else read -r -s answer </dev/tty || answer=""; fi
  printf '\\n'
  printf -v "$var" '%s' "$answer"
}`,
  'ask_secret via tty',
)

// the mode question and the "confirm" step use the same rule
edit(
  `if [ "$YES" != 1 ] && [ "$CHECK" != 1 ] && [ -t 0 ] && [ -z "$MODE" ]; then`,
  `if [ "$YES" != 1 ] && [ "$CHECK" != 1 ] && { [ -t 0 ] || [ -r /dev/tty ]; } && [ -z "$MODE" ]; then`,
  'mode question via tty',
)
edit(
  `  printf 'Mode [1]: '
  read -r mode_answer || mode_answer=""`,
  `  printf 'Mode [1]: '
  mode_answer="$(read_from_terminal)"`,
  'mode read via tty',
)

writeFileSync(path, source)
console.log('install.sh: prompts + no-deps')
