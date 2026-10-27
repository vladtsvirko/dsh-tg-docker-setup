# DSH backend in Docker

One container, two clients, one agent runtime:

```
  LAN browser ──► <host-lan-ip>:4310 ─┐
                                     ├──► dsh --profile web ──► agents / tools / sessions
  Telegram ────► api.telegram.org ───┘        │
                                              └── /data  (home + workspace, on the host)
```

The **container is the security boundary**. Inside it the harness runs with
`DSH_PERMISSION_MODE=danger-full-access`, i.e. its own bwrap/Landlock sandbox is
off — a nested sandbox inside a container is unreliable and *fails closed*, which
would break the bash tool. What the agent can touch is exactly what the image and
the `/data` volume expose; nothing else on the server is mounted.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Node 24 + dsh + pnpm, unprivileged `dsh` user, tini as PID 1 |
| `entrypoint.sh` | First-boot: profile init, adapter install, config pinning. Then `exec dsh` under the supervisor |
| `supervisor.mjs` | Owns restarts and the profile snapshot; trial restarts with automatic rollback |
| `supervisor.test.mjs` | End-to-end tests for the supervisor against a fake runtime (`node --test`) |
| `compose.yaml` | Hardened runtime: read-only rootfs, no caps, pids/mem caps, LAN-only port |
| `.env.example` | Every knob, with comments |
| `update.sh` | Check / apply / roll back dsh updates, refresh the adapter |
| `SECURITY.md` | Reporting, and the deployment's own rules |
| `LICENSE` | MIT |
| `.github/workflows/ci.yml` | Supervisor tests and shell syntax checks |
| `host-install/` | Alternative: run dsh on the host as a systemd service (no Docker) |

## Quick start

### Stage 1 — local only (no Telegram)

```sh
git clone https://github.com/vladtsvirko/dsh-tg-docker-setup.git
cd dsh-tg-docker-setup
cp .env.example .env          # ./data is created and fixed up automatically

# the two values that are easy to get wrong
sed -i "s|^DSH_UID=.*|DSH_UID=$(id -u)|; s|^DSH_GID=.*|DSH_GID=$(id -g)|" .env
sed -i "s|^DSH_BIND_IP=.*|DSH_BIND_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')|" .env
nano .env                     # add your provider key

docker compose build          # ~5 min first time, downloads dsh + its tree
docker compose up -d
docker compose logs -f dsh | grep 'dsh web:'
```

`DSH_BIND_IP` must be an address that exists on this machine — it is the interface
`docker` binds the published port to, so a stale or foreign value fails at `up`
with `cannot assign requested address`. The `ip route get` line above picks the
source address of the default route, which is the LAN IP you want.

That is a complete backend: the web UI, the agent, tools, sessions. Telegram is
not installed at all — the adapter is a git dependency and skipping it also keeps
the first boot offline-friendly and fast.

### Stage 2 — add Telegram later

```sh
nano .env                     # DSH_TELEGRAM_BOT_TOKEN=... ALLOWED_USER_IDS=...
docker compose up -d          # recreates the container; entrypoint installs the adapter
docker compose logs -f dsh
```

The entrypoint installs the adapter on that boot (behind both gates described
below), pins its config and starts polling. No rebuild, no image change — the
plugin lives in the `./data/home` volume.

To go the other way, empty the token (or set `DSH_TELEGRAM_ENABLED=off`) and
restart: the row is disabled in the profile patch, so the adapter stays on disk
but never mounts or polls, and flipping it back needs no re-download.

`DSH_TELEGRAM_ENABLED` is `auto` by default — the adapter runs exactly when a
token is present. `on` forces it (and warns if the token is missing), `off` keeps
it disabled even with a token.

In stage 1 the log shows `telegram: not configured — web UI only` and the runtime
is up in about two seconds (no plugin download at all). In stage 2 you additionally
see the adapter install plus its version exemption, roughly a minute.

Then find your web URL — it carries a `?token=` that the browser needs:

```sh
docker compose logs dsh | grep 'dsh web:'
```

Two things that look like bugs but aren't: the bare origin (`http://ip:4310/`)
answers **401 authentication required**, and the adapter logs almost nothing while
it polls happily. Real trouble surfaces as `poll error:` in the log, or
`⚠️ Agent error:` in the chat.

## Model route

Two routes work out of the box; the entrypoint writes the profile config for you.

| `.env` | Result |
|---|---|
| `DSH_PROVIDER=opencode-go`, `DSH_MODEL=deepseek-v4.1-flash`, `OPENCODE_GO_API_KEY=…` | Registers `opencode-go` on the pi-ai plugin with `apiKeyEnv: OPENCODE_GO_API_KEY`, and pins it as the default model |
| `DSH_PROVIDER=deepseek-official`, `DSH_MODEL=deepseek-v4-flash`, `DEEPSEEK_API_KEY=…` | No provider registration needed — it is the built-in route — just the model pin |

Anything else needs `DSH_PROVIDER_API_KEY_ENV` so the entrypoint knows which
variable holds the key. Changing the route is an `.env` edit plus a restart: the
managed `# >>> dsh-provider` block in
`data/home/profiles/web/cordis.patch.yml` is rewritten from scratch each boot, so
stale provider config never lingers (verified by switching opencode-go →
deepseek-official → back).

The route also decides what each Telegram chat gets, since the adapter pins the
same provider/model when it creates a session.

## Data layout

```
./data/home        DSH_HOME — profile, sessions, cron/settings, .env is NOT here
./data/workspace   the agent's working directory (what it reads and writes)
./data/supervisor  the stable profile snapshot + open trial state (see below)
```

These must be writable by the container's uid (image user = `DSH_UID`). You do
not need to create `./data`: the `init` service creates the directory if needed
and chowns it to `DSH_UID:DSH_GID` before `dsh` starts. If you remove or disable
that service, either create `./data` yourself or Docker will create it as root and
the runtime will fail with `mkdir: cannot create directory '/data/home'`.

`docker compose ps` shows the `init` service as `exited (0)` after a start; that
is normal — it is a one-shot ownership fix, not a daemon.

Both live on the host and are the only things that survive a rebuild. Back up
`./data/home` if you care about session history (it's the agent's memory), and
`./data/workspace` if you care about its files. Anything outside `/data` in the
container is disposable and disappears with the container.

## Knobs that matter

| Setting | Why |
|---|---|
| `DSH_PROVIDER` / `DSH_MODEL` | Model route. Default `opencode-go` / `deepseek-v4.1-flash`; `deepseek-official` / `deepseek-v4-flash` also supported. |
| `OPENCODE_GO_API_KEY` | Key for the default route. The entrypoint warns at boot if the matching variable is empty. |
| `DSH_PUBLIC_URL` | The root the browser dials for API + WebSocket. Defaults to `http://$DSH_BIND_IP:$DSH_PORT/`; set it when you use a hostname, proxy or VPN name. |
| `DSH_BIND_IP` | The web UI is published only on this host interface. `127.0.0.1` = host-only (use an SSH tunnel). Never publish on `0.0.0.0` — the UI drives a shell. |
| `DSH_UID` / `DSH_GID` | Must match the owner of `./data`, or the container can't write. `id -u; id -g`, then rebuild. |
| `ALLOWED_USER_IDS` | The only gate on Telegram. Empty rejects everyone (including you). |
| `DSH_TELEGRAM_ENABLED` | `auto` / `on` / `off`. Leave `auto`: the adapter is on exactly when a token is set. |
| `DSH_MEM_LIMIT` / `DSH_CPUS` / `pids_limit` | What stops one runaway command from taking the host down. |
| `DSH_PERMISSION_MODE` | Keep `danger-full-access`. Setting `workspace-write` re-enables the nested sandbox, which will fail closed in here. |
| `DSH_TRIAL_SECONDS` | Rollback window for a trial, default `300` (5 min). Waiting longer is safer for slow checks; shorter is easier on a broken bot. |
| `DSH_BOOT_GRACE_SECONDS` | How long a trial runtime may stay up without checking in, default `120`. After that it is rolled back. |
| `DSH_UPDATE_TIMEOUT_SECONDS` | How long `/update` may spend in `reset-plugin`, default `900`. |

## Compatibility

The image pins `DSH_VERSION` (default `0.2.1-rc.2`) and installs the connector
from `DSH_TELEGRAM_PLUGIN`. The supported pairs and the policy for moving them

are in the connector's [`COMPATIBILITY.md`](https://github.com/vladtsvirko/dsh-telegram-connector/blob/main/COMPATIBILITY.md).
Inside the bot, `/about` reports the connector version, the runtime version (the
image exports `DSH_RUNTIME_VERSION`) and the declared peer range.

Upgrading the image does not upgrade the connector by itself: the entrypoint
keeps an installed copy. Use the bot's `/update` (or
`docker compose run --rm dsh reset-plugin`) to move the connector too.

## Choosing the connector

`DSH_TELEGRAM_PLUGIN` decides which plugin gets installed and mounted:

| Ref | Model |
|---|---|
| `github:vladtsvirko/dsh-telegram-connector` | group = workspace, topic = session, control chat = private |
| `github:ben7am1n/dsh-telegram` | one chat = one session, flat |

The package name is derived from the ref (or set `DSH_TELEGRAM_PACKAGE`), because
the patch row, the install check and the version exemption all key off it. After
changing it, run `docker compose run --rm dsh reset-plugin` once — otherwise the
previous plugin stays installed and two pollers fight over the same token.

**The connector repo must be readable by the container.** A private repo needs a
token or deploy key inside the image; the simplest path is to make the connector
public, since it holds no secrets.

## Operating it

```sh
docker compose logs -f dsh            # runtime + adapter logs
docker compose exec dsh /usr/local/bin/dsh-healthcheck   # exit 0 = serving (this is what the healthcheck runs)
docker compose restart dsh            # after editing .env
docker compose exec dsh dsh --version # what's actually installed
docker compose run --rm dsh init      # re-run preparation only (e.g. new allowlist)
```

**Change the allowlist / model after first boot:** edit `./data/home/profiles/web/cordis.patch.yml`
directly (it's pinned once and left alone afterwards), then restart.

## Publisher bots

One bot has one budget: ~20 messages/minute in a group, shared by all topics.
When several sessions stream at once that is easy to exhaust. Optional
send-only bots multiply the ceiling:

```sh
DSH_TELEGRAM_PUBLISHER_TOKENS=123:AAA...,456:BBB...
```

- Only the main bot polls, owns inline buttons and creates topics; publishers
  just post and edit their own messages.
- **Add each publisher to every group yourself** — the Bot API cannot add a bot
  to an existing group. The main bot checks membership every six hours and posts
  a reminder in the group's system topic when one is missing.
- The bot's outbox keeps one queue per group, paced per bot, and shows a single
  status line while it waits. When every bot is saturated, the owner gets a
  digest in the bot chat (at most once per six hours) with a suggestion to add
  another publisher.
- Messages are delivered exactly once when the send is acknowledged; the only
  loss window is a crash between Telegram accepting and the acknowledgement, and
  those items are quarantined and counted, never duplicated.

## Restarts and rollback

The container runs the runtime under `supervisor.mjs` (tini → entrypoint →
supervisor → `dsh`), not under Docker's `restart` policy alone. The supervisor
is the only component that does not load plugins, which is the whole point: a
plugin that breaks startup must not be able to take the recovery path down with
it. It keeps a copy of the profile directory in `./data/supervisor/stable` and
can put it back without a network or a package manager.

From the bot chat:

| Command | Effect |
|---|---|
| `/restart` | restart into a trial: the new state is live and the previous one is kept for rollback |
| `/restart now` | restart without a trial; the current state becomes the rollback point |
| `/confirm` | commit the trial: this state becomes the new rollback point |
| `/rollback` | restore the last committed state and restart |
| `/update` | reinstall the connector itself: stop, run `reset-plugin`, start in a trial |

The trial announcement carries **Commit** and **Roll back** buttons; the
commands do the same thing. Every confirmed plugin change opens a trial *before*
it is applied: with HMR the change is live and the window is still open, without
HMR (or when the manager asks) the runtime restarts into it. The sequence is
change → confirm → trial → **Commit**.

The trial rolls back by itself in three cases:

- the trial runtime exits (bad plugin, crash) — immediately;
- it starts but the connector never checks in (so the bot cannot receive a
  confirmation) — after `DSH_BOOT_GRACE_SECONDS`;
- nobody confirms within `DSH_TRIAL_SECONDS` — the deadline started when the
  connector armed the trial.

If the container restarts mid-trial, the deadline is persisted: a trial still
inside its window resumes, an expired one is rolled back before the runtime
starts. The supervisor sends the rollback notice itself, since it knows the bot
token and the control chat id from `bindings.json`; the trial announcement comes
from the connector once it is up.

`/update` is the SSH step moved into the bot: the supervisor stops the runtime,
runs the entrypoint's own `reset-plugin` (including its allow-builds and version
compatibility handling), then starts the runtime inside a trial. If the reinstall
fails, the snapshot is restored before the runtime comes back.

Scope: this covers the **profile**, which is what plugins and their settings
live in. Sessions and the workspace are outside it and are untouched by a
rollback. It does not make image updates (`update.sh`) reversible, and a change
made directly in `./data/home` before the container starts is outside any trial.

## Updating dsh

`update.sh` is the whole story:

```sh
./update.sh --check     # 0 = current, 2 = newer published (cron-friendly)
./update.sh --status    # version, container health, adapter version, HTTP
./update.sh --apply     # backup, bump, rebuild --pull, restart, verify
./update.sh --rollback  # back to DSH_VERSION_PREVIOUS
./update.sh --plugin    # re-resolve the Telegram adapter from its git ref
```

`--apply` records the outgoing version in `DSH_VERSION_PREVIOUS`, tars
`data/home` into `backups/` (last 5 kept), rebuilds, waits for the healthcheck,
then checks the web port and greps the last 200 log lines for plugin complaints.
If the runtime doesn't come up, it stops and tells you to roll back.

**The one thing that breaks on every dsh upgrade.** The adapter is a git
dependency declaring `^0.1.0-rc.6` peers, and dsh only mounts it through an
*exact-version* exemption stored in `<profile>/compatibility.json`:

```json
{ "dsh-telegram@0.1.0": ["0.2.1-rc.3"] }
```

Neither a plugin upgrade nor a dsh upgrade inherits that permission — bump dsh
and the adapter is denied at load, so the bot disappears while the web UI keeps
working. The entrypoint now re-grants it on every boot (`ensure_compat`), so a
plain `docker compose build && up -d` is enough. If the adapter itself has
changed upstream, `--plugin` drops the plugin layer and re-installs it, then
re-grants.

### Staying on latest safely

`latest` for dsh means RC releases, and the adapter lags behind them. So "always
latest" is fine, but only as an *unattended, verified* bump rather than a floating
tag: the image bakes an exact version, `--check` tells you when it moves, and
`--rollback` is one command. Weekly cron on the host:

```cron
# Monday 04:17 — apply updates, keep a log, stay quiet unless something fails
17 4 * * 1 cd /home/YOU/docker && ./update.sh --apply >> /var/log/dsh-update.log 2>&1 || \
  echo "dsh update failed" | mail -s "dsh" you@example.com
```

### Other moving parts

| Layer | How it updates | Notes |
|---|---|---|
| dsh itself | `--apply` (`DSH_VERSION` in `.env`) | The only version that matters for compatibility |
| Node base image | `docker compose build --pull` | Follows `24-bookworm-slim` within 24.x |
| pnpm | rebuild | `pnpm@11` floats within 11.x |
| Telegram adapter | `--plugin` | Tracks its git ref at install time, not continuously |
| Other plugins | add via `dsh plugin`, pinned in the profile's `pnpm-lock.yaml` | Lives in `data/home`, survives rebuilds |
| Model names | `DSH_MODEL` in `.env` | Provider models change without any image change |

Nothing here auto-updates on its own: no watchtower, no floating tags. That is
deliberate — a container that silently changes the software running your shell is
a worse failure mode than a Monday morning bump you can roll back.

## Optional: lock down egress

The default bridge network allows any outbound connection. The runtime only needs
`api.telegram.org` and your LLM endpoint. If you want to enforce that, put the
container behind a proxy and set `HTTPS_PROXY` (Node 24 honours it when
`NODE_USE_ENV_PROXY=1`) — otherwise use host firewall rules keyed on the
container's subnet. Worth doing if you ever expose the bot to a group chat.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Container restarts, log shows permission denied on `/data` | UID mismatch | set `DSH_UID`/`DSH_GID`, `docker compose build` |
| `mkdir: cannot create directory '/data/home': Permission denied` | `./data` is root-owned (init service disabled, or created outside compose) | `sudo chown -R $(id -u):$(id -g) data`, `docker compose up -d` |
| `init` service exits non-zero | `./data` is not writable/owned as expected, or the image is missing | `docker compose logs init`; rebuild with `docker compose build` |
| `init: the image runs as 1000:1000 but .env says 1001:1001` | `DSH_UID`/`DSH_GID` changed after the image was built | `docker compose build`, then `docker compose up -d` |
| `No usable native binding found for node-addon-require-builtin-…` / `failed to map segment from shared object` | the addon loader caches `.node` files in `os.tmpdir()`, and Docker mounts `/tmp` with **noexec** | the image already sets `NARB_NATIVE_CACHE_DIR=/data/.cache/native`; if you override `TMPDIR` or that env, put it back on an exec-capable filesystem |
| `adapter install failed` in log | no egress during first boot, or the version gate | check `docker compose exec dsh cat /tmp/plugin-install.log`; then `docker compose run --rm dsh init` |
| Web UI 200 but API calls 403 | opened the bare origin instead of the `?token=` URL | use the URL from the log, or set `--trusted-host` |
| `failed to bind host port …: cannot assign requested address` | `DSH_BIND_IP` isn't an address of this host | derive it with `ip route get 1.1.1.1`, fix `.env`, `docker compose up -d` |
| `docker compose ps` shows `(health: starting)` for a long time | the probe runs every 10s; the first ones land before the runtime is listening | `docker compose exec dsh /usr/local/bin/dsh-healthcheck; echo $?` — `0` means it is serving, whatever `ps` says |
| UI loads but keeps saying **reconnecting** | the browser dials the address the container advertises (`172.x`), which it cannot reach | set `DSH_PUBLIC_URL` to the root you actually use, e.g. `http://192.0.2.10:4310/` (a documentation address; use your own) |
| Bot silent after a dsh upgrade | adapter no longer mounts | re-grant the exemption, or pin `DSH_VERSION` back |
| Bot says `⛔ You are not authorized` | your id isn't in `allowedUserIds` | edit `./data/home/profiles/web/cordis.patch.yml`, `docker compose restart dsh` |
| `no space left on device` | sessions + pnpm store in `/data/home` | prune old sessions, move `DSH_HOME` to a bigger volume |

## Why not just a Unix user?

A user account is a *capability* boundary, not a containment one: the agent can
still read anything world-readable (`/etc`, other services' configs, loose `~/.ssh`),
shares the host PID namespace, is unlimited in CPU/RAM, and — the big one — has
unrestricted network egress. DSH's own sandbox is file-effects only and says so
explicitly. The container closes all of that by default instead of requiring you
to audit it.
