#!/bin/sh
# Runtime readiness probe.
#
# dsh binds one interface (wildcard binds are rejected). Probe the address the
# deployment configured; when the caller did not pass it, fall back to the
# default-route address, then loopback. HTTP is preferred because it proves the
# carrier is dispatching, not just that a socket accepts; a bare TCP connect is
# the fallback for a host without a usable curl.
set -u
port="${DSH_PORT:-4310}"
host="${DSH_BIND_IP:-}"
if [ -z "$host" ] && command -v ip >/dev/null 2>&1; then
  host="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
fi
[ -n "$host" ] || host="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | head -n1)"
for host in "$host" 127.0.0.1; do
  [ -n "$host" ] || continue
  code="$(curl --noproxy '*' -s -o /dev/null -m 4 -w '%{http_code}' "http://${host}:${port}/" 2>/dev/null || true)"
  case "$code" in
    200|302|303|401|403) exit 0 ;;   # 401 is the normal answer: token required
  esac
  # fall back to a plain TCP connect (bash-only; the shebang is POSIX sh)
  if command -v bash >/dev/null 2>&1; then
    timeout 4 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null && exit 0
  fi
done
exit 1
