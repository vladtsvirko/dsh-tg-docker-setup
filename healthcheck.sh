#!/bin/sh
# Container readiness probe.
#
# dsh binds its own interface (wildcard binds are rejected), so the probe targets
# the container IP rather than loopback. HTTP is preferred because it proves the
# carrier is dispatching, not just that a socket accepts; a bare TCP connect is
# the fallback for the case where curl itself is unusable (proxy env, missing
# CA, ...), which would otherwise keep the container "starting" forever.
set -u
port="${DSH_PORT:-4310}"
ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$ip" ] || exit 1

code="$(curl --noproxy '*' -s -o /dev/null -m 4 -w '%{http_code}' "http://${ip}:${port}/" 2>/dev/null || true)"
case "$code" in
  200|302|303|401|403) exit 0 ;;   # 401 is the normal answer: token required
esac

# fall back to a plain TCP connect (bash-only syntax; the shebang is POSIX sh)
if command -v bash >/dev/null 2>&1; then
  timeout 4 bash -c "exec 3<>/dev/tcp/${ip}/${port}" 2>/dev/null && exit 0
fi
exit 1
