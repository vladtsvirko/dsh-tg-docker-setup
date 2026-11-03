#!/usr/bin/env bash
#
# Git identity and repository access for the runtime.
#
# Sourced by install.sh (which has the deployment variables) and testable on its
# own: `git_profile_json` prints the manifest and touches nothing.
#
# The manifest is the same one docs/GIT.md describes and `git-credentials.mjs`
# consumes; it lives where that script looks for it — /run/secrets/git in the
# container, $DIR/secrets/git natively (via DSH_GIT_SECRETS).

# Escape one value for a JSON string. Tokens are [A-Za-z0-9_-] in practice, but
# a self-hosted provider can hand out anything printable.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Print the manifest for one default profile.
#   git_profile_json <provider> <host> <token> <name> <email>
git_profile_json() {
  local provider="$1" host="$2" token="$3" name="$4" email="$5"
  printf '{\n  "default": {\n'
  printf '    "provider": "%s",\n' "$(json_escape "$provider")"
  printf '    "auth": "https",\n'
  if [ -n "$host" ]; then
    printf '    "host": "%s",\n' "$(json_escape "$host")"
  fi
  printf '    "token": "%s"' "$(json_escape "$token")"
  if [ -n "$name" ] && [ -n "$email" ]; then
    printf ',\n    "identity": { "name": "%s", "email": "%s" }' \
      "$(json_escape "$name")" "$(json_escape "$email")"
  fi
  printf '\n  },\n  "projects": {}\n}\n'
}

# Write the manifest where the runtime reads it, owned by the runtime user.
#   git_profile_write <dir> <owner> <provider> <host> <token> <name> <email>
git_profile_write() {
  local dir="$1" owner="$2" file
  shift 2
  file="$dir/profiles.json"
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  if [ -f "$file" ]; then
    cp "$file" "$file.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  fi
  # Build it beside the target and move it into place only when it parses: a
  # half-written manifest fails at the first git command, hours later.
  local temporary="$file.tmp"
  git_profile_json "$@" > "$temporary" || { rm -f "$temporary"; return 1; }
  if command -v node >/dev/null 2>&1; then
    node -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))' "$temporary" 2>/dev/null \
      || { rm -f "$temporary"; printf '[!] the git profile is not valid JSON — check the token for control characters\n' >&2; return 1; }
  fi
  mv "$temporary" "$file" || return 1
  chmod 600 "$file" 2>/dev/null || true
  [ -n "$owner" ] && chown -R "$owner" "$(dirname "$dir")" 2>/dev/null || true
  printf '%s\n' "$file"
}
