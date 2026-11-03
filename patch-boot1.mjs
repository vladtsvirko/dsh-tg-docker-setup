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

// --- 1. helpers before the bootstrap, and no cd until the repo exists ------
edit(
  `set -euo pipefail

cd "$(dirname "$0")"
SRC_DIR="$(pwd -P)"
SETUP_VERSION="$(tr -d '\\n' < "$SRC_DIR/VERSION")"
DSH_VERSION="$(printf '%s' "$SETUP_VERSION" | sed -E 's/-[0-9]+\\.[0-9]+\\.[0-9]+$//')"`,
  `set -euo pipefail

log()  { printf '\\033[1;36m==>\\033[0m %s\\n' "$*"; }
warn() { printf '\\033[1;33m[!]\\033[0m %s\\n' "$*" >&2; }
die()  { printf '\\033[1;31m[x]\\033[0m %s\\n' "$*" >&2; exit 1; }

# Where this file is, without assuming it is a file: \`wget -qO- … | bash\` has
# no path at all, and the bootstrap below handles that case.
if [ -n "\${BASH_SOURCE[0]:-}" ] && [ -f "\${BASH_SOURCE[0]}" ]; then
  SRC_DIR="$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd -P)"
else
  SRC_DIR="$(pwd -P)"
fi

# --- bootstrap: one downloaded file is enough ------------------------------
# The installer needs VERSION, compose.yaml, the Dockerfile and the entrypoint
# next to it. Given only this script, fetch a release checkout first and hand
# over to the copy inside it.
if [ ! -f "$SRC_DIR/VERSION" ] || [ ! -f "$SRC_DIR/compose.yaml" ]; then
  # shellcheck source=/dev/null
  . /dev/stdin <<'BOOTSTRAP'
BOOTSTRAP
fi`,
  'header split',
)

writeFileSync(path, source)
console.log('stage 1 written')
