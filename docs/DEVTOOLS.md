# Mobile build toolchains (optional)

DSH runs without them. They are **host tools**, like Penpot is a host stack:
not plugins, not containers, and not part of the DSH data snapshot. A setup
update never reinstalls or replaces them.

```
setup.sh install --devtools ios,android     # or answer the install question
setup.sh devtools status
setup.sh devtools install --tools android
setup.sh devtools remove --tools ios
```

`--devtools` accepts `none`, `ios`, `android` or `all`. The answer is stored as
`DSH_DEVTOOLS` in `.env`. On a fresh interactive install the installer asks
once; `--yes` leaves it `none` unless the flag or an answers file says
otherwise. Re-running the installer keeps the deployed answer and does not
reinstall anything unless `--devtools` is given again.

Versions are pinned in [`devtools.json`](../devtools.json) and are independent
of setup releases. Bumping them is a normal setup change, but it only takes
effect on `setup.sh devtools install`; `/system update setup` leaves the
installed trees alone.

## iOS: Swift and xtool

```sh
sudo ./setup.sh devtools install --tools ios
```

Installed:

| Piece | What it is |
|---|---|
| Swift 6.4.2 | the compiler and SwiftPM, unpacked under `/opt/dsh-devtools/swift-6.4.2` |
| xtool 1.24.0 | the AppImage, under `/opt/dsh-devtools/xtool-1.24.0`, linked as `/usr/local/bin/xtool` |
| usbmuxd, libimobiledevice tools | device communication, for deploy and `xtool devices` |

The `/usr/local/bin/xtool` launcher extracts the AppImage into the user's
`~/.cache/dsh-xtool` instead of mounting it with FUSE, which is more reliable on
a server or in a container.

`xtool` replaces Xcode's build path for **SwiftPM apps**. It is not a Mac, and
it does not ship Apple's SDK. Both modes below still need **Xcode.xip**,
downloaded from <https://developer.apple.com/download/all/> while signed in.
It is large (tens of GB unpacked) and its license is yours to accept.

### Development without an Apple account

`xtool sdk install` needs the Xcode file, but **not** an Apple login:

```sh
sudo ./setup.sh devtools sdk --xcode /path/to/Xcode.xip
```

This builds the Darwin SDK in the service user's home. Then development works:

```sh
xtool new MyApp
cd MyApp
xtool dev build          # builds; ad-hoc signed
```

`xtool dev build` does not require a token. Without one, the following refuse:

- `xtool dev run` — builds and installs to a device; needs a token.
- `xtool dev build --sign` — signing; needs a token.
- `xtool install` — device install; needs a token.

That is the boundary: no Apple token, no deploy. It is enforced by xtool, not by
a setup flag. The agent runs as the same `dsh` user, so it gets exactly the
same build-only ability.

The setup command above uses a disk-backed `TMPDIR`
(`<dir>/data/home/.cache/tmp`) because extracting Xcode into a 4 GB `/tmp`
tmpfs fails. Do the same if you run the command by hand:

```sh
sudo -u dsh -H env HOME=/srv/dsh/data/home \
  TMPDIR=/srv/dsh/data/home/.cache/tmp \
  xtool sdk install /path/to/Xcode.xip
```

### Deploy: opt in to Apple login

Deploying or signing is a deliberate second step:

```sh
sudo ./setup.sh devtools login       # runs `xtool auth login` as dsh
```

It asks for an Apple ID and, for the password mode, a 2FA code. A free Apple ID
works in password mode; a paid Apple Developer Program membership enables the
API-key mode. The token is stored in the service user's home.

After that:

```sh
xtool dev run            # build, sign and install on the connected iPhone
xtool dev build --sign
```

`sudo ./setup.sh devtools logout` clears the token; `auth-status` checks it.
`xtool setup` is equivalent to `xtool auth` followed by `xtool sdk` — use it
only when you want login and SDK in one step, not for the dev-only setup.

> **What the boundary does and does not mean.** Once a token is in the `dsh`
> home, the agent can deploy too; the token is the permission. If the human
> should deploy but the agent should not, use a **separate OS user** for the
> Apple login and device work, or log out after deploying. Do not put an Apple
> password in the workspace or in a prompt.

For device deployment, the host must see the iPhone over USB (`usbmuxd` does
that on a normal machine). A VM needs USB passthrough; a CI runner usually
builds an `.ipa` and lets a Mac or a device service install it.

Scope: SwiftPM projects. React Native, Flutter and Xcode-project builds are a
different toolchain; xtool does not make an `.xcodeproj` build on Linux.

## Android: JDK, SDK, NDK

```sh
sudo ./setup.sh devtools install --tools android
```

Installed:

| Piece | Version |
|---|---|
| OpenJDK | 21 when the distro has it, otherwise 17 (`JAVA_HOME` is written to `.env`) |
| Android command-line tools | `15859902` |
| platform-tools (`adb`, `fastboot`) | latest for the pinned channel |
| SDK platform | `android-36` |
| build-tools | `36.1.0` (`aapt2`, `apksigner`, `d8`, …) |
| NDK | `30.0.16248370` |
| SDK CMake | `3.22.1` |

Everything lives under `/opt/dsh-devtools/android-sdk` and is root-owned. The
agent can execute the tools but cannot install more SDK packages; use
`sudo sdkmanager ...` for that. Android Studio and the emulator are **not**
installed: a native build needs neither, and the emulator needs a desktop, KVM
and a lot of disk.

`install` runs `sdkmanager --licenses` and accepts the Android SDK license on
this host. That is what choosing `android` consents to. Project dependencies
are still downloaded by Gradle into the project's own cache, as usual.

The runtime gets `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `ANDROID_NDK_HOME`,
`ANDROID_NDK_ROOT` and `JAVA_HOME` from `.env`; interactive shells get the same
values from `/etc/profile.d/dsh-devtools.sh`. Restart the service after a
post-install change:

```sh
sudo systemctl restart dsh.service
```

Build with the project's Gradle wrapper (`./gradlew assembleDebug`); Gradle
itself is intentionally not installed system-wide, because every project pins
its own.

## Disk, OS and architecture

Each toolchain needs roughly 7 GB free; installing both needs about 14 GB.
The installer checks free space under `/opt` before downloading and stops with
the exact shortfall instead of filling the disk.

Swift builds are selected for Ubuntu 22.04/24.04/26.04 and Debian 12/13.
Android's command-line tools are x86_64 only. Other distributions or
architectures fail with a message rather than installing a toolchain that will
not run.

## Update and removal policy

- `setup.sh update` and `/system update setup` do **not** touch these trees.
  They are outside the data snapshot and outside the setup's rollback.
- `setup.sh devtools install` is idempotent and **adds** to the deployed set:
  asking for `ios` when Android is installed leaves Android installed. Use
  `setup.sh devtools remove` to drop one, or `setup.sh install --devtools ...`
  to replace the whole answer. An installed version is skipped, missing SDK
  packages are reconciled, and launchers are refreshed. A repair run
  (`setup.sh install` with the stored answer) deliberately does **not** rerun
  the installer; `setup.sh devtools install` is the retry path for a missing
  tree.
- `setup.sh devtools remove` deletes the tool trees and the launchers, keeps
  apt packages (they may be shared), and rewrites `.env` for whatever remains.
  It does not delete project caches under the workspace or Gradle's `~/.gradle`.
- Like Penpot, the toolchains are independent of DSH: removing DSH does not
  remove them.

## Security notes

Both toolchains execute code from projects the agent builds. That is the point,
but it widens what a compromised workspace can do: build scripts run as the
service user, and xtool holds an Apple session in that user's home. The binaries
themselves are root-owned under `/opt`, so the runtime cannot replace the
compilers, but it can run them.

`xtool setup` credentials live in the service user's home. Treat that home as a
credential store, like the git manifest and the Penpot token.
