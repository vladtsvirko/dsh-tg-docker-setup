#!/usr/bin/env bash
#
# Optional host toolchains for building mobile apps on this machine:
#
#   ios      Swift + xtool. xtool builds SwiftPM packages into iOS apps and
#            deploys them to a device. It is not a Mac and it does not include
#            Apple's SDK: `xtool setup` still needs an Apple ID and Xcode.xip.
#   android  OpenJDK + Android command-line tools, platform, build-tools, NDK
#            and CMake. No Android Studio and no emulator.
#
# setup.sh calls this for an install; the same file backs `setup.sh devtools`.
# These are host tools outside the DSH data snapshot, so a setup update never
# replaces them. Versions live in devtools.json and change only with a release.
#
#   scripts/devtools.sh plan --tools ios,android
#   sudo scripts/devtools.sh install --tools all
#   scripts/devtools.sh status
#   sudo scripts/devtools.sh remove --tools ios
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CATALOG="$HERE/../devtools.json"
ROOT="${DSH_DEVTOOLS_ROOT:-}"
TOOLS=""
ACTION=""
DEPS=1
SERVICE_USER=""
SERVICE_HOME="/srv/dsh/data/home"

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

need_catalog() {
  [ -r "$CATALOG" ] || die "devtools.json is missing beside scripts/ — run this from a release checkout"
  command -v node >/dev/null 2>&1 || die "node is required to read devtools.json"
}

catalog() {
  # catalog <tool> <field>; arrays print one item per line.
  node -e '
    const fs = require("node:fs")
    const [file, tool, field] = process.argv.slice(1)
    const c = JSON.parse(fs.readFileSync(file, "utf8"))
    const value = tool === "" ? c[field] : (c.tools[tool] || {})[field]
    if (value === undefined || value === null) process.exit(2)
    if (Array.isArray(value)) process.stdout.write(value.join("\n"))
    else process.stdout.write(String(value))
  ' "$CATALOG" "$1" "$2"
}

normalize_tools() {
  local raw="${1:-}" out="" part
  local -a parts
  raw="${raw//[[:space:]]/}"
  case "$raw" in
    ""|none|None|NONE) printf 'none'; return 0 ;;
    all|All|ALL) printf 'ios,android'; return 0 ;;
  esac
  local ios=0 android=0
  IFS=',' read -r -a parts <<<"$raw"
  for part in "${parts[@]}"; do
    case "$part" in
      ios|iOS|IOS) ios=1 ;;
      android|Android|ANDROID) android=1 ;;
      *) die "unknown toolchain: $part (known: ios, android, all, none)" ;;
    esac
  done
  [ "$ios" = 1 ] && out="ios"
  if [ "$android" = 1 ]; then
    [ -n "$out" ] && out="$out,android" || out="android"
  fi
  [ -n "$out" ] || out=none
  printf '%s' "$out"
}

has_tool() {
  case ",$TOOLS," in *",$1,"*) return 0 ;; esac
  return 1
}

need_root() {
  [ "$(id -u)" = 0 ] || die "installing host toolchains needs root — re-run with sudo"
  case "$ROOT" in
    ""|/) die "refusing to use / as the toolchain root" ;;
  esac
}

disk_gate() {
  local need_mb="$1" avail_kb avail_mb
  mkdir -p "$ROOT" 2>/dev/null || true
  avail_kb="$(df -Pk "$ROOT" | awk 'NR == 2 { print $4 }')"
  avail_mb=$((avail_kb / 1024))
  if [ "$avail_mb" -lt "$need_mb" ]; then
    die "not enough disk under $ROOT: ${avail_mb} MiB free, ${need_mb} MiB needed — free space or install one toolchain at a time"
  fi
}

# Downloads and extraction stay on the toolchain filesystem. /tmp is a tmpfs on
# many hosts (4 GB here), and a 1.1 GB Swift tarball plus its unpacked tree does
# not fit; a full disk there left a half-extracted toolchain that looked done.
work_tmp() {
  mkdir -p "$ROOT" || return 1
  mktemp -d "$ROOT/.tmp.XXXXXX"
}

apt_updated=0
apt_install() {
  [ "$DEPS" = 1 ] || die "missing packages and --no-deps was given: $*"
  command -v apt-get >/dev/null 2>&1 || die "this is not a Debian/Ubuntu host — install $* yourself"
  if [ "$apt_updated" = 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt-get update failed; trying anyway"
    apt_updated=1
  fi
  log "installing packages: $*"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@"
}

apt_available() {
  apt-cache show "$1" >/dev/null 2>&1
}


# One wrapper in /usr/local/bin, never clobbering a tool the host already has.
link_tool() {
  local name="$1" target="$2" current
  current="$(command -v "$name" 2>/dev/null || true)"
  if [ -n "$current" ] && [ "$current" != "/usr/local/bin/$name" ]; then
    warn "$name is already provided by $current — leaving it alone; use $target directly"
    return 0
  fi
  if [ -e "/usr/local/bin/$name" ] && ! grep -qs "$ROOT" "/usr/local/bin/$name"; then
    warn "/usr/local/bin/$name is not managed by $ROOT — leaving it alone"
    return 0
  fi
  cat >"/usr/local/bin/$name" <<EOF
#!/bin/sh
exec "$target" "\$@"
EOF
  chmod 0755 "/usr/local/bin/$name"
}


swift_arch_suffix() {
  case "$(uname -m)" in
    x86_64) printf '' ;;
    aarch64|arm64) printf '%s' '-aarch64' ;;
    *) die "unsupported architecture: $(uname -m) (x86_64 and aarch64 only)" ;;
  esac
}


# The tarball name uses the dotted distro version (ubuntu24.04), while the web
# directory does not (ubuntu2404). Build both from the same pair.
swift_distro() {
  local id ver
  # shellcheck disable=SC1091
  . /etc/os-release
  id="${ID:-}"; ver="${VERSION_ID:-}"
  case "$id" in
    ubuntu) printf 'ubuntu%s' "$ver" ;;
    debian) printf 'debian%s' "$ver" ;;
    *) die "unsupported distribution: ${id:-unknown}" ;;
  esac
}

swift_webdir_os() {
  swift_distro | tr -d '.'
}

swift_url() {
  local ver="$1" distro webdir arch
  distro="$(swift_distro)"
  webdir="$(swift_webdir_os)"
  arch="$(swift_arch_suffix)"
  printf 'https://download.swift.org/swift-%s-release/%s%s/swift-%s-RELEASE/swift-%s-RELEASE-%s%s.tar.gz' \
    "$ver" "$webdir" "$arch" "$ver" "$ver" "$distro" "$arch"
}

swift_tarball_top() {
  local ver="$1" distro arch
  distro="$(swift_distro)"
  arch="$(swift_arch_suffix)"
  printf 'swift-%s-RELEASE-%s%s' "$ver" "$distro" "$arch"
}

android_cmdline_url() {
  local ver="$1"
  printf 'https://dl.google.com/android/repository/commandlinetools-linux-%s_latest.zip' "$ver"
}

xtool_url() {
  local ver="$1" arch
  case "$(uname -m)" in
    x86_64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
  printf 'https://github.com/xtool-org/xtool/releases/download/%s/xtool-%s.AppImage' "$ver" "$arch"
}

download() {
  local url="$1" file="$2"
  command -v curl >/dev/null 2>&1 || die "curl is required"
  log "downloading $(basename "$file")"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 -o "$file" "$url" \
    || die "download failed: $url"
}

ensure_iOS_deps() {
  # The packages the official Swift Dockerfile installs for this distro, with
  # versioned gcc/libstdc++ names resolved to whatever this release ships.
  local gcc stdc
  apt_install binutils libc6-dev libcurl4-openssl-dev libedit2 libpython3-dev \
    libsqlite3-0 libxml2-dev libncurses-dev libz3-dev pkg-config tzdata zlib1g-dev || return 1
  gcc=""
  for gcc in libgcc-13-dev libgcc-14-dev libgcc-15-dev libgcc-dev; do
    apt_available "$gcc" && break
  done
  [ -n "$gcc" ] || die "cannot find a libgcc development package"
  apt_install "$gcc" || return 1
  stdc=""
  for stdc in libstdc++-13-dev libstdc++-14-dev libstdc++-15-dev libstdc++-dev; do
    apt_available "$stdc" && break
  done
  [ -n "$stdc" ] || die "cannot find a libstdc++ development package"
  apt_install "$stdc" || return 1
  # Device communication; not needed for simulator builds, but this is the iOS
  # stack, and xtool's device subcommands expect it.
  apt_install usbmuxd libimobiledevice-utils || warn "usbmuxd is missing — device deploy will not work"
}

install_swift() {
  local ver dir tmp top url
  ver="$(catalog ios swift)"
  dir="$ROOT/swift-$ver"
  if [ -x "$dir/usr/bin/swift" ]; then
    log "Swift $ver already installed in $dir"
  else
    ensure_iOS_deps || return 1
    disk_gate "$(catalog ios minFreeMB)" || return 1
    tmp="$(work_tmp)" || return 1
    url="$(swift_url "$ver")"
    download "$url" "$tmp/swift.tar.gz" || { rm -rf "$tmp"; return 1; }
    top="$(swift_tarball_top "$ver")"
    log "unpacking Swift $ver"
    if ! tar -xzf "$tmp/swift.tar.gz" -C "$tmp"; then
      rm -rf "$tmp"
      return 1
    fi
    if [ ! -d "$tmp/$top" ]; then
      rm -rf "$tmp"
      die "unexpected Swift tarball layout (no $top)"
    fi
    rm -rf "$dir"
    if ! mv "$tmp/$top" "$dir"; then rm -rf "$tmp"; return 1; fi
    rm -rf "$tmp"
  fi
  [ -x "$dir/usr/bin/swift" ] || { warn "Swift tree at $dir is incomplete"; return 1; }
  local tool
  for tool in swift swiftc swift-build swift-package swift-run swift-test swift-sdk swift-format; do
    [ -x "$dir/usr/bin/$tool" ] && link_tool "$tool" "$dir/usr/bin/$tool"
  done
  [ -x "$dir/usr/bin/sourcekit-lsp" ] && link_tool sourcekit-lsp "$dir/usr/bin/sourcekit-lsp"
  local version
  version="$("$dir/usr/bin/swift" --version 2>&1 | head -1)" || return 1
  [ -n "$version" ] || { warn "Swift at $dir does not run"; return 1; }
  log "Swift ready: $version"
}

install_xtool() {
  local ver dir bin tmp
  ver="$(catalog ios xtool)"
  dir="$ROOT/xtool-$ver"
  bin="$dir/xtool"
  if [ -x "$bin" ]; then
    log "xtool $ver already installed in $dir"
  else
    disk_gate 200 || return 1
    tmp="$(work_tmp)" || return 1
    download "$(xtool_url "$ver")" "$tmp/xtool.AppImage" || { rm -rf "$tmp"; return 1; }
    mkdir -p "$dir" || { rm -rf "$tmp"; return 1; }
    if ! mv "$tmp/xtool.AppImage" "$bin"; then rm -rf "$tmp"; return 1; fi
    chmod 0755 "$bin"
    rm -rf "$tmp"
  fi
  if [ -e /usr/local/bin/xtool ] && ! grep -qs "$ROOT" /usr/local/bin/xtool; then
    warn "/usr/local/bin/xtool is not managed by $ROOT — leaving it alone; use $bin directly"
  else
  # FUSE is not reliable on a server or in a container, and an AppImage that
  # fails to mount leaves a confusing error. Extracting is slower but always
  # works; the binary is only ~52 MB.
  # Per-user extraction cache. A shared /tmp path is hashed by the AppImage
  # runtime; the root install leaves it root-owned, so the service user cannot
  # recreate it. HOME is per-user and already writable.
  cat >/usr/local/bin/xtool <<EOF
#!/bin/sh
cache="\${XDG_CACHE_HOME:-\$HOME/.cache}/dsh-xtool"
mkdir -p "\$cache" 2>/dev/null || cache=/tmp
TMPDIR="\$cache" APPIMAGE_EXTRACT_AND_RUN=1 exec "$bin" "\$@"
EOF
  chmod 0755 /usr/local/bin/xtool
  fi
  APPIMAGE_EXTRACT_AND_RUN=1 "$bin" --help >/dev/null 2>&1 \
    || die "xtool installed but did not run — check the AppImage and its per-user cache"
  log "xtool ready: $ver"
}

ensure_android_deps() {
  local pkg found=0
  apt_install unzip || return 1
  for pkg in $(catalog android java | tr '\n' ' '); do
    if apt_available "$pkg"; then
      apt_install "$pkg" || return 1
      found=1; break
    fi
  done
  [ "$found" = 1 ] || die "no OpenJDK package found (tried openjdk-21/17)"
  command -v javac >/dev/null 2>&1 || die "javac is still missing after installing the JDK"
}

java_home() {
  local javac
  javac="$(command -v javac 2>/dev/null || true)"
  [ -n "$javac" ] || return 1
  dirname "$(dirname "$(readlink -f "$javac")")"
}

sdkmanager_bin() {
  printf '%s/android-sdk/cmdline-tools/latest/bin/sdkmanager' "$ROOT"
}

install_android() {
  local ver sdk tmp url pkg rc log_file
  [ "$(uname -m)" = x86_64 ] || die "the Android command-line tools are x86_64 only (found $(uname -m))"
  ver="$(catalog android cmdlineTools)"
  sdk="$ROOT/android-sdk"
  disk_gate "$(catalog android minFreeMB)" || return 1
  ensure_android_deps || return 1
  mkdir -p "$sdk/cmdline-tools" || return 1
  if [ ! -x "$sdk/cmdline-tools/latest/bin/sdkmanager" ]; then
    tmp="$(work_tmp)" || return 1
    url="$(android_cmdline_url "$ver")"
    download "$url" "$tmp/cmdline-tools.zip" || { rm -rf "$tmp"; return 1; }
    log "unpacking Android command-line tools $ver"
    if ! unzip -q "$tmp/cmdline-tools.zip" -d "$tmp/unpack"; then rm -rf "$tmp"; return 1; fi
    if [ ! -d "$tmp/unpack/cmdline-tools" ]; then rm -rf "$tmp"; die "unexpected command-line tools layout"; fi
    rm -rf "$sdk/cmdline-tools/latest"
    if ! mv "$tmp/unpack/cmdline-tools" "$sdk/cmdline-tools/latest"; then rm -rf "$tmp"; return 1; fi
    rm -rf "$tmp"
  else
    log "Android command-line tools already installed"
  fi

  JAVA_HOME="$(java_home)" || return 1
  export JAVA_HOME
  export ANDROID_HOME="$sdk"
  export ANDROID_SDK_ROOT="$sdk"
  local sm
  sm="$(sdkmanager_bin)"
  log "accepting the Android SDK licenses on this host"
  set +o pipefail
  yes | "$sm" --sdk_root="$sdk" --licenses >/dev/null 2>&1 || true
  rc=${PIPESTATUS[1]}
  set -o pipefail
  [ "$rc" -eq 0 ] || die "sdkmanager could not accept the SDK licenses"

  log "installing Android SDK packages: $(catalog android packages | tr '\n' ' ')"
  log_file="$(mktemp "${TMPDIR:-/tmp}/dsh-sdkmanager.XXXXXX.log")"
  set +o pipefail
  yes | "$sm" --sdk_root="$sdk" --install $(catalog android packages) >"$log_file" 2>&1 || true
  rc=${PIPESTATUS[1]}
  set -o pipefail
  if [ "$rc" -ne 0 ]; then
    tail -n 30 "$log_file" >&2 || true
    rm -f "$log_file"
    die "sdkmanager failed to install the Android SDK packages"
  fi
  rm -f "$log_file"

  # adb and the build-tools are plain binaries; sdkmanager/avdmanager need the
  # JDK, which is not on PATH by default.
  [ -x "$sdk/platform-tools/adb" ] && link_tool adb "$sdk/platform-tools/adb"
  [ -x "$sdk/platform-tools/fastboot" ] && link_tool fastboot "$sdk/platform-tools/fastboot"
  local bt
  bt="$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)"
  if [ -n "$bt" ]; then
    for pkg in aapt2 apksigner zipalign d8 dexdump; do
      [ -x "$bt/$pkg" ] && link_tool "$pkg" "$bt/$pkg"
    done
  fi
  cat >/usr/local/bin/sdkmanager <<EOF
#!/bin/sh
export JAVA_HOME="\${JAVA_HOME:-$(java_home)}"
export ANDROID_HOME="$sdk"
export ANDROID_SDK_ROOT="$sdk"
exec "$sm" "\$@"
EOF
  chmod 0755 /usr/local/bin/sdkmanager
  cat >/usr/local/bin/avdmanager <<EOF
#!/bin/sh
export JAVA_HOME="\${JAVA_HOME:-$(java_home)}"
export ANDROID_HOME="$sdk"
export ANDROID_SDK_ROOT="$sdk"
exec "$sdk/cmdline-tools/latest/bin/avdmanager" "\$@"
EOF
  chmod 0755 /usr/local/bin/avdmanager

  local ndk
  ndk="$(find "$sdk/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)"
  cat >/etc/profile.d/dsh-devtools.sh <<EOF
# Written by dsh setup.sh devtools. The runtime gets the same values from .env.
export ANDROID_HOME="$sdk"
export ANDROID_SDK_ROOT="$sdk"
export JAVA_HOME="$(java_home)"
EOF
  [ -n "$ndk" ] && printf 'export ANDROID_NDK_HOME="%s"\nexport ANDROID_NDK_ROOT="%s"\n' "$ndk" "$ndk" >>/etc/profile.d/dsh-devtools.sh
  printf 'case ":\$PATH:" in *":%s/platform-tools:"*) ;; *) export PATH="%s/platform-tools:%s/cmdline-tools/latest/bin:\$PATH" ;; esac\n' \
    "$sdk" "$sdk" "$sdk" >>/etc/profile.d/dsh-devtools.sh
  chmod 0644 /etc/profile.d/dsh-devtools.sh
  log "Android SDK ready: $sdk (JDK $JAVA_HOME)"
}

plan() {
  local tool
  if [ "$TOOLS" = none ]; then
    printf 'none — DSH runs without them\n'
    return 0
  fi
  for tool in ios android; do
    has_tool "$tool" || continue
    case "$tool" in
      ios)
        printf 'iOS: Swift %s + xtool %s (~7 GB; xtool setup still needs an Apple ID and Xcode.xip)\n' \
          "$(catalog ios swift)" "$(catalog ios xtool)"
        ;;
      android)
        printf 'Android: JDK, SDK %s, build-tools %s, NDK %s (~7 GB; installing accepts the SDK license)\n' \
          "$(catalog android platform)" \
          "$(catalog android packages | sed -n 's/^build-tools;//p')" \
          "$(catalog android packages | sed -n 's/^ndk;//p')"
        ;;
    esac
  done
}

status() {
  local tool missing=0
  if [ "$TOOLS" = none ]; then
    printf 'devtools  none\n'
    return 0
  fi
  for tool in ios android; do
    has_tool "$tool" || continue
    case "$tool" in
      ios)
        if [ -x "$ROOT/swift-$(catalog ios swift)/usr/bin/swift" ] && [ -x "$ROOT/xtool-$(catalog ios xtool)/xtool" ]; then
          printf 'ios       installed (Swift %s, xtool %s)\n' "$(catalog ios swift)" "$(catalog ios xtool)"
        else
          printf 'ios       missing (expected Swift %s and xtool %s under %s)\n' \
            "$(catalog ios swift)" "$(catalog ios xtool)" "$ROOT"
          missing=1
        fi
        ;;
      android)
        if [ -x "$(sdkmanager_bin)" ] && [ -d "$ROOT/android-sdk/platforms/$(catalog android platform)" ]; then
          printf 'android   installed (%s)\n' "$ROOT/android-sdk"
        else
          printf 'android   missing (expected SDK %s under %s/android-sdk)\n' "$(catalog android platform)" "$ROOT"
          missing=1
        fi
        ;;
    esac
  done
  [ "$missing" = 0 ] || return 1
}

remove_tool() {
  local tool="$1" name target
  case "$tool" in
    ios)
      rm -rf "$ROOT/swift-"* "$ROOT/xtool-"*
      for name in swift swiftc swift-build swift-package swift-run swift-test swift-sdk swift-format sourcekit-lsp xtool; do
        target="/usr/local/bin/$name"
        [ -e "$target" ] || continue
        grep -qs "$ROOT" "$target" && rm -f "$target"
      done
      ;;
    android)
      rm -rf "$ROOT/android-sdk"
      for name in sdkmanager avdmanager adb fastboot aapt2 apksigner zipalign d8 dexdump; do
        target="/usr/local/bin/$name"
        [ -e "$target" ] || continue
        grep -qs "$ROOT" "$target" && rm -f "$target"
      done
      rm -f /etc/profile.d/dsh-devtools.sh
      ;;
  esac
  log "removed $tool from $ROOT (apt packages are kept)"
  return 0
}

install_all() {
  local rc=0
  need_root
  mkdir -p "$ROOT"
  if has_tool ios; then
    if install_swift; then
      install_xtool || rc=1
    else
      rc=1
    fi
  fi
  if has_tool android; then
    install_android || rc=1
  fi
  if [ "$rc" -eq 0 ] && has_tool ios; then
    local user="${SERVICE_USER:-dsh}"
    printf '\nxtool is installed, but its Apple SDK is not.\n' >&2
    printf 'Run once as the runtime user, on this host:\n' >&2
    printf '  sudo -u %s -H env HOME=%s xtool setup\n' "$user" "$SERVICE_HOME" >&2
    printf 'It asks for your Apple ID and the Xcode.xip you downloaded from developer.apple.com.\n' >&2
    printf 'Until then `swift sdk list` has no darwin SDK and xtool cannot build for iOS.\n' >&2
  fi
  return "$rc"
}

while [ $# -gt 0 ]; do
  case "$1" in
    plan|status|install|remove) ACTION="$1"; shift ;;
    --tools) TOOLS="${2:?--tools needs a value}"; shift 2 ;;
    --tools=*) TOOLS="${1#*=}"; shift ;;
    --root) ROOT="${2:?--root needs a value}"; shift 2 ;;
    --root=*) ROOT="${1#*=}"; shift ;;
    --service-user) SERVICE_USER="${2:?--service-user needs a value}"; shift 2 ;;
    --service-user=*) SERVICE_USER="${1#*=}"; shift ;;
    --home) SERVICE_HOME="${2:?--home needs a value}"; shift 2 ;;
    --home=*) SERVICE_HOME="${1#*=}"; shift ;;
    --no-deps) DEPS=0; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

need_catalog
[ -n "$ROOT" ] || ROOT="$(catalog '' root)"
[ -n "$TOOLS" ] || TOOLS="${DSH_DEVTOOLS:-none}"
TOOLS="$(normalize_tools "$TOOLS")"
[ -n "$ACTION" ] || ACTION=status

case "$ACTION" in
  plan) plan ;;
  status) status ;;
  install) install_all ;;
  remove)
    need_root
    for tool in ios android; do
      if has_tool "$tool"; then remove_tool "$tool"; fi
    done
    exit 0
    ;;
esac
