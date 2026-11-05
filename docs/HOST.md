# The host deployment

`install.sh` turns this machine into a DSH host: two systemd units, an
unprivileged service user, a root-owned checkout, and the data directory that
survives everything else. This page is the reference for that layout, the
isolation it does and does not give, and the update authority.

## Units

| Unit | User | What it does |
|---|---|---|
| `dsh.service` | `dsh` (the service user) | `entrypoint.sh serve` → `supervisor.mjs` → `dsh` |
| `dsh-updater.service` | `root` | `updater.mjs` on `127.0.0.1:8787`, bearer token; runs `update.sh --to` |

The runtime is unprivileged. The updater is root because restarting
`dsh.service` requires it — that is the only reason. The updater has no
published port: only the loopback interface, only with the token from `.env`.

## Layout

```
/srv/dsh/                the setup checkout (a git clone at a release tag)
/srv/dsh/data/home       DSH_HOME — profile, sessions, connector state
/srv/dsh/data/workspace  the agent's working directory
/srv/dsh/data/supervisor supervisor state and the stable profile snapshot
/srv/dsh/data/.cache     HOME caches (pnpm, npm, native addons)
/srv/dsh/.env            port, tokens, resource share — 0640 root:dsh
/srv/dsh/secrets/git     repository credentials — 0700, 0600 files
/usr/local/bin/dsh-*     symlinks into the checkout (entrypoint, supervisor,
                         healthcheck, updater, git credentials, penpot)
```

`/srv/dsh` is root-owned; the data directory is owned by the service user. An
update can therefore be a `git checkout` without leaving root-owned profile
files behind, and the runtime cannot rewrite the code that starts it.

## Containers

The unit is always hardened (`ProtectSystem=strict`, `ProtectHome=yes`,
`PrivateTmp`, `NoNewPrivileges`, `ReadWritePaths=<dir>/data`). DSH itself runs
with `DSH_PERMISSION_MODE=danger-full-access`; the unit is the filesystem
boundary.

| Runtime | Who | Purpose |
|---|---|---|
| rootless Podman as `dsh` | the agent | disposable test containers, `podman run --rm` |
| rootful Podman | the updater (root) | the optional Penpot stack, `podman-compose` |

Docker is not installed or used. `--containers none` skips Podman entirely.
Rootless Podman needs `/etc/subuid`/`/etc/subgid` for `dsh` and `uidmap`; the
installer adds them. Penpot's data lives in `<dir>/design/data` and is kept
across `podman-compose down`.

## Resource limits

The installer asks for a CPU/RAM share and proposes **30% of the machine**
(`0` = unlimited). It becomes:

```ini
MemoryMax=30%
CPUQuota=<percent × cores>%
TasksMax=512
```

`MemoryMax` is a percentage of RAM; `CPUQuota` is measured against one core, so
a share of the machine is `percent × nproc`. Unlimited writes none of the three.
The value is stored as `DSH_RESOURCE_PERCENT` in `.env`, so a repair keeps it;
change it there and re-run `./install.sh` (the unit is rewritten) or edit the
unit and `systemctl daemon-reload`.

## Install and repair

```sh
./install.sh                 # asks the questions, writes units, starts
./install.sh --check         # the plan, nothing changed
./install.sh --containers none --yes
./install.sh --config answers.env
./install.sh --ref <git ref>
```

A native install run as a normal user re-executes itself under `sudo`, and the
mode/answers already given are kept. `--dir` moves the deployment directory
(default `/srv/dsh`). The installer is idempotent: a re-run repairs the units,
the symlinks and `.env`, keeps the deployed values (including the provider key
and the resource share), and does not move data. A failed re-run is not rolled
back — the files are written before the health check.

`./install.sh --doctor` (and `./update.sh --doctor`) check the same things;
`--fix` repairs the safe subset: duplicate or CRLF `.env` lines, a provider key
the web UI's stored copy shadows, a duplicated managed block in the profile
patch, wrong ownership. Every install and every successful self-update runs it
with `--fix`.

Only one runtime may own a data directory. The entrypoint takes a kernel lock
and writes `data/.runtime.json`; a second runtime over the same `data` waits 20 s
and refuses to start, naming the holder. Both processes would hold each other's
session write handles, the web UIs would disagree about the workspace list, and
Telegram would answer "this session is held by another client". `--doctor`
reports a live marker from a different checkout.

## Updates

Both paths end in the same script and the same tag policy.

| Trigger | Path |
|---|---|
| Telegram `/system update setup` | connector → `dsh-updater.service` (127.0.0.1:8787, bearer token) → `update.sh --to <tag>` |
| Host `./update.sh --apply` | `update.sh --apply` (root) |
| Telegram `/system update connector` | supervisor → `entrypoint reset-plugin`, profile only |

The apply path:

1. snapshot `data/home` + `data/supervisor` to `backups/self-*.tgz`;
2. check out the target tag;
3. write `DSH_SETUP_VERSION` into `.env`;
4. install the matching `@deepseek-ai/dsh` globally when it differs;
5. re-run the entrypoint's prepare step as the service user (this installs the
   recommended plugin refs from `plugins.json`, enforcing only their minimum);
6. `systemctl restart dsh.service`;
7. health gate: service active **and** the published web port answers.

On failure it checks the previous tag out again, restores the snapshot, rewrites
the version and restarts.

A release that changes `install.sh` itself (the systemd units) needs one
`sudo ./install.sh --yes` afterwards: it is idempotent and keeps the values
already in `.env`. The updater reports the outcome to the control chat.

Compatibility rules are unchanged: same DSH part and same product major may
jump; crossing either needs `--i-know-versions-are-incompatible`, which the
connector passes through.

## Security notes

- Keep `/srv/dsh/.env` at `0640 root:dsh`. It holds the bot token, the model key
  and the updater token.
- The updater token is a root credential: the updater runs `update.sh` and
  restarts the runtime.
- The runtime and the connector share the `dsh` uid, so the agent can read the
  bot and updater tokens. That is inherent to one unprivileged runtime; if it is
  not acceptable, run the deployment on a dedicated host or VM.
- Do not add the service user to the `docker` group. The agent uses rootless
  Podman; the rootful Penpot stack is the updater's job.
- The systemd hardening blocks writes outside `<dir>/data`; do not add
  `ReadWritePaths` casually.
- If the host also holds other projects' secrets, prefer a VM: the agent can
  read what `dsh` can read.

## What still needs the host

Fixing a broken `.env`, a wedged service, a full disk, a failed rollback, or a
host that cannot boot the runtime. Telegram remains the normal control path, not
a recovery guarantee; [LIMITS.md](LIMITS.md) lists the boundary.
