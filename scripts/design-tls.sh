#!/usr/bin/env bash
#
# Generate the local CA and the Penpot TLS certificate.
#
# The design stack is served over plain HTTP on DSH_DESIGN_PORT for the agent
# and for the LAN. Browsers only expose the clipboard API on a secure origin,
# so Penpot's "Copy" button cannot work there; the TLS sidecar publishes the
# same frontend over HTTPS on DSH_DESIGN_TLS_PORT.
#
# One CA is created per deployment and kept forever: the operator trusts it
# once, and a renewed or re-issued server certificate keeps working. The server
# certificate is re-issued when the bind address changes or when it is close to
# expiring.
#
# Usage: design-tls.sh <design-dir> <bind-ip>
#   <design-dir>  directory that contains compose.yaml (usually /srv/dsh/design)
#   <bind-ip>     address the browser will use; added to the certificate SAN
#
# Exit: 0 when certs/ca.crt and certs/server.crt are in place, 1 otherwise.
set -euo pipefail

dir="${1:?usage: design-tls.sh <design-dir> <bind-ip>}"
bind="${2:?usage: design-tls.sh <design-dir> <bind-ip>}"
certs="$dir/certs"

command -v openssl >/dev/null 2>&1 || { printf 'openssl is required for the Penpot TLS certificate\n' >&2; exit 1; }

mkdir -p "$certs"
chmod 755 "$certs"

# One CA per deployment. Its key never leaves the host; the certificate is the
# file the operator installs in the browser's trust store.
if [ ! -s "$certs/ca.key" ] || [ ! -s "$certs/ca.crt" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$certs/ca.key" -out "$certs/ca.crt" -days 3650 \
    -subj "/CN=DSH Penpot Local CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
  chmod 600 "$certs/ca.key"
  chmod 644 "$certs/ca.crt"
fi

san="DNS:localhost,IP:127.0.0.1"
[ "$bind" = "127.0.0.1" ] || san="$san,IP:$bind"

need=1
if [ -s "$certs/server.crt" ] && [ -s "$certs/server.key" ]; then
  # Keep a certificate that still covers this address and has a week left.
  if openssl x509 -in "$certs/server.crt" -noout -checkend 604800 >/dev/null 2>&1 &&
     openssl x509 -in "$certs/server.crt" -noout -text 2>/dev/null | grep -qF "IP Address:$bind"; then
    need=0
  fi
fi

if [ "$need" = 1 ]; then
  openssl req -newkey rsa:2048 -nodes \
    -keyout "$certs/server.key" -out "$certs/server.csr" \
    -subj "/CN=$bind" >/dev/null 2>&1
  printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$san" > "$certs/server.ext"
  openssl x509 -req -in "$certs/server.csr" \
    -CA "$certs/ca.crt" -CAkey "$certs/ca.key" -CAcreateserial \
    -out "$certs/server.crt" -days 825 -extfile "$certs/server.ext" >/dev/null 2>&1
  rm -f "$certs/server.csr" "$certs/server.ext"
  chmod 600 "$certs/server.key"
  chmod 644 "$certs/server.crt"
fi

[ -s "$certs/ca.crt" ] && [ -s "$certs/server.crt" ] || exit 1
printf '%s\n' "$certs/ca.crt"
