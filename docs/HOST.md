# Native (no-Docker) deployment

The setup ships two deployment modes from one release. `install.sh` picks one:

| Mode | Runtime | Boundary |
|---|---|---|
| `docker` | compose: `init` + `dsh` + `updater` | the container |
| `native` | systemd: `dsh.service` + `dsh-updater.service` | the Unix user |

Both modes run the same supervisor, the same entrypoint preparation and the same
`update.sh` tag policy. They differ in what the agent can reach and in who holds
the update authority. Read this page before choosing native.

## What native mode is

- One systemd service, `dsh.service`, running `dsh-entrypoint serve` as the
  service user. `entrypoint → supervisor → dsh`, exactly as in the container.
- A second service, `dsh-updater.service`, running the same `updater.mjs` that
  the container runs as a sidecar, bound to **127.0.0.1 only** and authenticated
  with `DSH_UPDATER_TOKEN`. It exists so `/system update all` behaves the same
  from Telegram in both modes.
- No Docker, no image, no Docker socket anywhere — the runtime is a systemd
  unit. Docker is installed only when you also choose the Penpot design stack,
  which is a set of containers and needs it.

## What native mode is not

- **It is not a sandbox.** The agent runs with
  `DSH_PERMISSION_MODE=danger-full-access` and can read anything the service
  user can read: other projects under `/srv`, the host's world-readable files,
  the network. The container is the only mode where that is not true.
- **Root is not an option.** The installer offers `sandbox` (default) and
  `privileged` (adds the `docker` group, i.e. root-equivalent through Docker).
  "Run as root" is what a throwaway VM is for; it is deliberately not a flag.
- **There is no image rollback.** A failed update is rolled back by checking the
  previous tag out again and restoring the profile snapshot; there is no
  `self-previous` image to return to.

## Tiers

| Tier | What it adds | Trade |
|---|---|---|
| `sandbox` | systemd hardening (`ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp`, `NoNewPrivileges`, `ReadWritePaths=<dir>/data`) | no `apt`, no Docker, no writes outside the data directory |
| `privileged` | `SupplementaryGroups=docker` | Docker access = root-equivalent by design |

## Layout

```
/srv/dsh/                the setup checkout (a git clone at a release tag)
/srv/dsh/data/home       DSH_HOME — profile, sessions, connector state
/srv/dsh/data/workspace  the agent's working directory
/srv/dsh/data/supervisor supervisor state and the stable profile snapshot
/srv/dsh/data/.cache     HOME caches (pnpm, npm, native addons)
/srv/dsh/.env            mode, port, model route, tokens — 0640 root:dsh
/usr/local/bin/dsh-*     symlinks into the checkout (entrypoint, supervisor,
                         healthcheck, updater)
```

`/srv/dsh` is root-owned; the data directory is owned by the service user. That
is why an update can be a `git checkout` without leaving root-owned profile
files behind.

## Install

```sh
./install.sh                 # asks for the mode and the few values that matter
./install.sh --check         # print the plan, change nothing
./install.sh --mode native --yes
./install.sh --config answers.env   # MODE, DIR, DSH_PORT, tokens, ...
./install.sh --ref <git ref>        # install a specific ref (default: the release tag)
```

Or with nothing but a URL, on a fresh host:

```sh
wget -qO- https://raw.githubusercontent.com/vladtsvirko/dsh-tg-docker-setup/main/install.sh \
  | sudo bash -s -- --mode native
```

That fetches the newest release into `/opt/dsh-setup` (as root), installs Node 22
from NodeSource when the host has none, and then continues with the questions
below. `--no-deps` keeps the installer away from apt when Node is managed
elsewhere; `--check` shows the whole plan, including what it would install.

The installer is idempotent: re-running repairs the units, the symlinks and the
`.env`. It refuses to clobber the other mode silently — switching is explicit
(see below). A native install run as a normal user re-executes itself under
`sudo` before asking anything, so the questions are asked once.

## Updates

Both paths end in the same script and the same tag policy.

| Trigger | Path |
|---|---|
| Telegram `/system update all` | connector → `dsh-updater.service` (127.0.0.1:8787, bearer token) → `update.sh --self-to <tag>` |
| Host `./update.sh --self` | `update.sh --self` (root) |
| Telegram `/system update connector` | supervisor → `entrypoint reset-plugin`, profile only |

The native apply path:

1. snapshot `data/home` + `data/supervisor` to `backups/self-*.tgz`;
2. check out the target tag;
3. write `DSH_SETUP_VERSION` into `.env`;
4. re-run the entrypoint's prepare step as the service user (this installs the
   connector tag derived from the new version);
5. `systemctl restart dsh.service`;
6. health gate: service active **and** the published web port answers.

On failure it checks the previous tag out again, restores the snapshot, rewrites
the version and restarts.

A release that changes `install.sh` itself (the systemd units) needs one
`sudo ./install.sh --mode native --yes` afterwards: it is idempotent and keeps
the values already in `.env`. The updater reports the outcome to the control chat,
exactly as in Docker mode.

Compatibility rules are unchanged: same DSH part and same product major may
jump; crossing either needs `--i-know-versions-are-incompatible`, which the
connector passes through.

Native updates run as root (the updater service is root because restarting
`dsh.service` requires it). The runtime itself never runs as root.

## Switching modes

```sh
./install.sh --mode native      # from a docker deployment
./install.sh --mode docker      # from a native deployment
```

Data lives in `<dir>/data` and the two modes have different default
directories: docker uses the checkout, native uses `/srv/dsh`. `install.sh`
stops the other mode first (one poller per bot token) and chowns the new data
directory, but it does not copy anything. To switch without losing the profile,
sessions and workspace, either install both modes with the same `--dir`, or copy
`data/` across before the first start of the new mode:

```sh
sudo ./install.sh --mode native --dir /srv/dsh --check   # plan first
sudo rsync -a ./data/ /srv/dsh/data/                     # then carry the data over
sudo ./install.sh --mode native --dir /srv/dsh
```

The Telegram token, the updater token and the model route carry over from
`.env`; copy that file too if the directories differ.

What changes is the update authority: in Docker mode the agent cannot touch its
runtime; in native mode it owns the checkout.

## Security notes

- Keep `/srv/dsh/.env` at `0640 root:dsh`. It holds the bot token, the model key
  and the updater token.
- The updater token is a root credential: the updater runs `update.sh` and
  restarts the runtime.
- Do not add the service user to the `docker` group unless you mean to give the
  agent Docker (and therefore root).
- The systemd hardening blocks writes outside `/srv/dsh/data`; do not add
  `ReadWritePaths` casually.
- If the host also holds other projects' secrets, prefer Docker mode or a VM.

## What still needs the host

As in Docker mode: fixing a broken `.env`, a wedged service, a full disk, a
failed rollback, or a host that cannot boot the runtime. Telegram remains the
normal control path, not a recovery guarantee.
