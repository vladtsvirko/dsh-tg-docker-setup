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

**First time here?** [docs/FIRST-RUN.md](docs/FIRST-RUN.md) is the short
walkthrough — one command, the web link, the Telegram group, and how to move a
session between the two. This page is the reference behind it.

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
| `updater.mjs`, `updater.Dockerfile` | Privileged sidecar for `/system update all`; no published port |
| `docs/FIRST-RUN.md` | The guided first run: install, web link, Telegram group, switching clients |
| `docs/VERSIONS.md` | Version scheme, release coupling and update rules |
| `docs/UPGRADE.md` | Upgrading, the health gate vs. a trial, and the rollback drill |
| `docs/SELF-UPDATE.md` | `update.sh --self` in detail, including native mode |
| `docs/UPDATER.md` | The privileged sidecar behind `/system update all` |
| `docs/GIT.md` | Repository access: HTTPS tokens and SSH keys, per workspace |
| `docs/UAT.md` | The acceptance run for a release, both modes |
| `docs/LIMITS.md` | What works without a host shell, what still needs one, and the hard limits |
| `install.example.env` | Every answer `install.sh --config` accepts, in one file |
| `host-install/` | **Superseded** (pre-`install.sh` host setup); kept for reference only |
| `SECURITY.md` | Reporting, and the deployment's own rules |
| `LICENSE` | MIT |
| `.github/workflows/ci.yml` | Supervisor tests and shell syntax checks |
| `install.sh` | One-command installer for both modes: interactive, `--check` for a dry run, `--doctor [--fix]` to diagnose/repair |
| `scripts/repair.sh` | The health check both `install.sh --doctor` and `update.sh --doctor` run; `--fix` repairs the safe subset |
| `scripts/credentials.mjs` | Reads and reconciles `data/home/.credentials.yaml` without printing a secret |
| `scripts/git-manifest.mjs` | Builds or merges `secrets/git/profiles.json` from the installer's accounts |
| `design/` | Optional Penpot stack + the `penpot` CLI for design work (`--design docker`) |
| `docs/DESIGN.md` | The design stack: install, token, the plugin and CLI, data, removal |
| `docs/HOST.md` | Native (no-Docker) deployment: tiers, layout, updates, switching |
| `docs/PARITY.md` | Native vs Docker: what is identical, what is intentionally different, and the native-first rule |
| `docs/UPSTREAM-WATCH.md` | The daily check for a new DSH release candidate, and the upgrade plans it produces |

## Before you start

The installer cannot create these; have them ready or the first run ends with a
working runtime and no bot.

| You need | Why | Where |
|---|---|---|
| A fresh Ubuntu 24.04 / Debian 12 host (or any distro with the packages below) | the installer targets these | your VPS or machine |
| Docker + Compose (docker mode) or Node ≥ 22.19 + systemd (native) | the runtime | **the installer installs them** — Docker via apt, Node via NodeSource — unless you pass `--no-deps` |
| A provider API key | the agent cannot answer without one | the installer now asks for it |
| A bot token | the Telegram surface | [@BotFather](https://t.me/BotFather) → `/newbot` |
| **Privacy mode off** for that bot | otherwise it never sees plain messages in topics, which is the whole input path | `/setprivacy` → Disable |
| A group with **Topics enabled**, bot as admin with *Manage Topics* | groups are workspaces, topics are sessions | group settings |
| Your numeric Telegram id | the allow-list is empty by default and the bot refuses everyone else | [@userinfobot](https://t.me/userinfobot) |

The bot cannot create the group; `/workspace new` prints a one-tap
`?startgroup=` link, and you create it.

## Install

### From the internet, on a fresh machine

One file, no checkout, and it installs what the chosen mode needs — Docker and
the compose plugin for docker mode, Node 22 for native mode:

```sh
wget -qO- https://raw.githubusercontent.com/vladtsvirko/dsh-tg-docker-setup/main/install.sh | bash
```

Run it as a normal user with `sudo` available, or as root. It:

1. says what it is going to fetch (the newest release tag) and where
   (`/opt/dsh-setup` as root, `~/dsh-setup` otherwise),
2. downloads that release into a git checkout — which is what makes
   `/system update all` work later,
3. asks the same questions as a local install, then shows the plan and asks
   before changing anything: `Proceed? [Y/n]`,
4. asks what the agent should commit as (git author name and email) and, optionally,
   for repository access: one or more git accounts (github, gitlab, gitea, forgejo
   or self-hosted), each over an HTTPS token or an SSH key. A GitHub account can
   reuse the token `gh auth login` already stores; an SSH account can generate a
   key and print its public half. The manifest is
   `<dir>/secrets/git/profiles.json`, mode 0600, and a re-run merges into it,
5. installs git always, Docker when the mode or the design stack needs it, Node for
   native, then the runtime, then waits for the health check.

`--check` shows the whole plan first, including what would be installed:

```sh
wget -qO- https://raw.githubusercontent.com/vladtsvirko/dsh-tg-docker-setup/main/install.sh | bash -s -- --check
```

Unattended, with every answer in a file (see `install.example.env`):

```sh
curl -fsSL …/install.sh | bash -s -- --yes --config answers.env
```

The release the one-liner fetches is the newest tag; pin it with `--ref
v0.2.1-rc.5-0.7.0`. `--dir` moves where the one-liner checks the release out
(default `/opt/dsh-setup` as root, `~/dsh-setup` otherwise); in docker mode the
deployment then runs from that checkout, so it is not a "data elsewhere" flag —
native mode is the one with a separate `/srv/dsh` default. If Docker or Node is
already installed and you would rather manage it yourself, pass `--no-deps`: the
installer then fails with the exact command to run instead of touching apt.

`--check` needs `git` to fetch the release it is going to describe; on a host
without git it can only say so and exit.

### From a checkout

```sh
git clone https://github.com/vladtsvirko/dsh-tg-docker-setup
cd dsh-tg-docker-setup
./install.sh --check        # the full plan, nothing changed
./install.sh                # interactive: mode, port, key, bot token, admin
```

One command, two modes — the same release, the same tag policy:

```sh
./install.sh                 # interactive: asks for the mode and the few key values
./install.sh --check         # print the plan, change nothing
./install.sh --mode native --yes
```

- **docker** (default) — the compose stack; the container is the security
  boundary and the agent cannot reach the host.
- **native** — a systemd service on this host, no Docker at all; the agent runs
  as an unprivileged user and *can* reach the host. Tiers, layout, update
  behaviour and how to switch modes are in [docs/HOST.md](docs/HOST.md).

Both modes update from Telegram the same way (`/system update all` goes
through the updater), and the host keeps `./update.sh --self`.

Switching modes stops the other mode first (one poller per bot token) but does
**not** move data: the defaults are `./data` for docker and `/srv/dsh/data` for
native, so point both at the same directory with `--dir`, or copy the data over
yourself, before switching. [docs/HOST.md](docs/HOST.md) walks through it.

## First run

Use the installer — it asks the questions, writes `.env`, installs the
connector at the pinned tag, starts the runtime under the supervisor, creates an
updater token, and finishes with a health check:

```sh
./install.sh
```

Then:

1. **Open the web UI.** The installer reads the runtime's log and prints the
   signed URL (it carries a `?token=`). If it could not read the log, the bare
   origin it falls back to answers **401** on purpose — the signed link is in
   the runtime log:

   ```sh
   docker compose logs dsh | grep 'dsh web:'      # native: journalctl -u dsh.service | grep 'dsh web:'
   ```

   That URL is a credential, and a restart mints a new one.
2. **Bind a Telegram group.** In the bot chat: `/workspace new web-app`, tap the
   `?startgroup=` link, and pick a group with **Topics** enabled and the bot as
   admin. `/new` in its General topic starts a session; a topic is a session.
3. **Check both sides.** `/system status` reports the runtime, the web port, the
   key, and how many workspaces the registry and Telegram each know.

[docs/FIRST-RUN.md](docs/FIRST-RUN.md) walks the same steps with the failure
modes; [docs/UAT.md](docs/UAT.md) is the exhaustive acceptance run.

### Switching between Telegram and the web UI

One runtime, one profile, one session store: the two clients are views of the
same thing, not two installations.

- `/web` in the bot chat prints a signed link into the same sessions. Treat it
  like a password.
- A prompt sent in the browser is echoed into that session's topic (`💬 you
  (web) · …`), and its answer appears in both places.
- A session has **one live agent**. If a browser tab holds it, a Telegram prompt
  is refused and a **Take over** button appears; the message is queued, and
  taking over restarts the runtime — releasing *every* handle, not just that
  session's — then delivers it. Closing the tab is the cheaper move.
- A session created in Telegram is an ordinary DSH session, so the web UI lists
  it. The other direction needs `/sync` in the group to give each web session a
  topic.

There is no export/import between the surfaces; the runtime is the only store.

## Manual install (advanced, compose only)

`install.sh` is the supported path because it also does what this section does
not: an updater token (without one `/system update all` is only a diagnostic), a
git author for the agent's commits, the profile repair pass, and the mode
switch. Use the manual path only when building an image by hand or debugging
the stack.

### Stage 1 — local only (no Telegram)

```sh
git clone https://github.com/vladtsvirko/dsh-tg-docker-setup.git
cd dsh-tg-docker-setup
cp .env.example .env          # ./data is created and fixed up automatically

# the two values that are easy to get wrong
sed -i "s|^DSH_UID=.*|DSH_UID=$(id -u)|; s|^DSH_GID=.*|DSH_GID=$(id -g)|" .env
sed -i "s|^DSH_BIND_IP=.*|DSH_BIND_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')|" .env
nano .env                     # add your provider key

# optional: private git repositories (see docs/GIT.md)
# cp -r secrets.example secrets && chmod -R go-rwx secrets
# $EDITOR secrets/git/profiles.json

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

**One key, one place.** The runtime resolves a provider key in this order: a
credential stored by the web UI's Models page, then the process environment
(what compose and systemd export from `.env`), then `.env` files. A key saved
once in the Models page therefore wins over every later `.env` edit, which is
why a repair that "wrote the key" could leave model calls failing. The installer
keeps the deployed key instead of asking again (`--rotate-key` when you mean to
replace it), writes exactly one key variable per route, and reconciles an
existing `data/home/.credentials.yaml` to the `.env` value.
`./install.sh --doctor` reports a stored key that `.env` does not have.

The route also decides what each Telegram chat gets, since the adapter pins the
same provider/model when it creates a session.

**The picker only offers what this deployment can actually call.** A provider
appears once it has a usable credential — a key in the environment, or a saved
API key for the built-in route — and a route without one is hidden from the
model selector; a saved `models` list replaces the offered set. On the
`deepseek-official` route the list follows DeepSeek's published `/models`
listing (refreshed in the background, built-in catalog when the call fails), so
a model DeepSeek publishes later shows up without a release, and a listed model
that needs a newer harness is refused before it is sent.

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
| `DSH_PUBLIC_URL` | The root the browser dials for API + WebSocket, and the only authority trusted for the web app. Defaults to `http://$DSH_BIND_IP:$DSH_PORT/`; set it when you use a hostname, proxy or VPN name. With `DSH_BIND_IP=127.0.0.1` you **must** set it (see below). |
| `DSH_BIND_IP` | The web UI is published only on this host interface. `127.0.0.1` = host-only, normally via `ssh -L <port>:127.0.0.1:<port>`; also set `DSH_PUBLIC_URL=http://127.0.0.1:<port>/`, otherwise the UI advertises the container address and reconnects forever. Never publish on `0.0.0.0` — the UI drives a shell. |
| `DSH_UID` / `DSH_GID` | Must match the owner of `./data`, or the container can't write. `id -u; id -g`, then rebuild. |
| `ALLOWED_USER_IDS` | Who may use the bot. Empty rejects everyone (including you). |
| `DSH_ADMIN_USER_ID` | The one account allowed to restart, update, roll back, install plugins and create/bind workspaces. Blank means the control-chat owner, so an upgraded deployment cannot lock itself out. |
| `DSH_TELEGRAM_ENABLED` | `auto` / `on` / `off`. Leave `auto`: the adapter is on exactly when a token is set. |
| `DSH_MEM_LIMIT` / `DSH_CPUS` / `pids_limit` | What stops one runaway command from taking the host down. |
| `DSH_PERMISSION_MODE` | Keep `danger-full-access`. Setting `workspace-write` re-enables the nested sandbox, which will fail closed in here. |
| `DSH_TRIAL_SECONDS` | Rollback window for a trial, default `300` (5 min). Waiting longer is safer for slow checks; shorter is easier on a broken bot. |
| `DSH_BOOT_GRACE_SECONDS` | How long a trial runtime may stay up without checking in, default `120`. After that it is rolled back. |
| `DSH_UPDATE_TIMEOUT_SECONDS` | One variable, two deadlines: the supervisor's connector/component jobs default to `900` (15 min), the updater's setup apply to `1800` (30 min). The compose updater does not read `.env` (no `env_file`), so in docker mode the apply deadline is fixed at 30 min unless you add the variable to that service. |
| `DSH_UPDATER_TOKEN` | Shared bearer token for the updater sidecar. Empty makes the sidecar answer `503` and `/system update all` degrade to a diagnostic that prints the host fallback — but the socket-mounted sidecar still runs. Stop or remove the `updater` service if you do not want that surface at all. |
| `DSH_DOCKER_GID` | GID of the host docker group; lets the updater use the socket without root. `getent group docker \| cut -d: -f3`. |

## Versioning and compatibility

The connector and the setup ship as **one tag**:

```
<dsh-version>-<major>.<minor>.<patch>      v0.2.1-rc.5-0.7.0
         DSH part          product part
```

- The DSH part is the exact tested runtime. It is hardcoded in the image tag and
  `Dockerfile`; there is no `DSH_VERSION` `.env` knob.
- Product `0.x` is compatible. A new major is a break. The product part resets to
  `0.0.0` when the pair moves to a new DSH line.
- Same DSH part and same product major may jump (`0.1.1 → 0.4.2`).
- Crossing a DSH line or product major requires the explicit
  `--i-know-versions-are-incompatible`; neither `/system` nor a scheduled update
  crosses on its own.
- Tags are immutable. The setup `VERSION`, image tags and Dockerfile args must
  agree, and this repository's CI checks exactly those on a `v*` tag. The
  connector `package.json` must carry the same version, but each repository only
  checks its own half — the pair is enforced by the release checklist, not by a
  cross-repository gate.

The entrypoint does not float the connector. It forces
`github:vladtsvirko/dsh-telegram-connector#v${DSH_SETUP_VERSION}` (the setup tag)
and reinstalls when that ref changes. Therefore:

- a setup release **needs** a matching connector tag — even when only setup code
  changed;
- a connector change deployed through the image **needs** a setup release with
  the same version;
- `/system update connector` reinstalls the **pinned** connector; it does not
  select a newer connector tag.

### What 1.0 will mean

`0.x` is the compatible line. A first `1.0.0` is not planned until these hold,
each one backed by a test or a drill:

1. **Upgrades are safe without flags** across minors, in both modes, including a
   rollback that can be triggered from Telegram — `docs/UPGRADE.md` is the drill.
2. **Data and configuration survive an upgrade** with no hand-editing:
   `bindings.json`, `.env`, the profile and the workspace.
3. **The surface is stable**: commands, environment names and the tag scheme stop
   moving between minors.
4. **Any failure is recoverable without reading the source**, from the chat or
   with the two commands in `docs/LIMITS.md`.

Known limits that 1.0 will not remove, and that are documented rather than
hidden: the agent cannot send files to Telegram, one admin account owns the
deployment-wide commands, and the provider key is the only thing that makes the
agent answer — `/system status` reports both.

The full policy, release checklist and coupling rules are in
[`docs/VERSIONS.md`](docs/VERSIONS.md). The connector's tested DSH rows are in
[`COMPATIBILITY.md`](https://github.com/vladtsvirko/dsh-telegram-connector/blob/main/COMPATIBILITY.md).
Inside the bot, `/about` reports the connector version, runtime version and
updater state.

What still needs the host — and what a failed update can and cannot restore — is
in [`docs/LIMITS.md`](docs/LIMITS.md).

## Choosing the connector

`DSH_TELEGRAM_PLUGIN` decides which plugin gets installed and mounted. Empty
(the default) means this setup's connector, pinned to the setup version:

| Ref | Model |
|---|---|
| *(empty)* | group = workspace, topic = session, control chat = private, version = setup tag |
| `github:ben7am1n/dsh-telegram` | one chat = one session, flat |

The package name is derived from the ref (or set `DSH_TELEGRAM_PACKAGE`), because
the patch row, the install check and the version exemption all key off it. After
changing it, run `docker compose run --rm dsh reset-plugin` once — otherwise the
previous plugin stays installed and two pollers fight over the same token.

**The connector repo must be readable by the container.** A private repo needs a
token or deploy key inside the image; the simplest path is to make the connector
public, since it holds no secrets.

Before the first upgrade you actually need, read
[`docs/UPGRADE.md`](docs/UPGRADE.md) and run its rollback drill.

## Operating it

```sh
docker compose logs -f dsh            # runtime + adapter logs
docker compose exec dsh /usr/local/bin/dsh-healthcheck   # exit 0 = serving (this is what the healthcheck runs)
docker compose up -d dsh              # recreate after editing .env (restart keeps the old env)
docker compose exec dsh dsh --version # what's actually installed
docker compose run --rm dsh init      # re-run preparation only (e.g. new allowlist)
```

**Change the allowlist / model after first boot:** edit `.env` (`ALLOWED_USER_IDS`,
`DSH_MODEL`, `OPENCODE_GO_API_KEY`/`DEEPSEEK_API_KEY`), then `docker compose up -d dsh`.

Do not edit `data/home/profiles/web/cordis.patch.yml` for this: the entrypoint
regenerates its managed `# >>> dsh-telegram` and `# >>> dsh-provider` blocks from
`.env` on every boot, so a hand edit there is reverted without a message.

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

## Repository access (git)

Private repositories get credentials from one JSON manifest: a `default`
account, host-scoped `hosts` (one per forge), and optional per-workspace
`projects`. The installer fills it in — one account, or several — and a re-run
merges new accounts instead of replacing the file. To do it by hand:

```sh
cp -r secrets.example secrets
chmod -R go-rwx secrets
$EDITOR secrets/git/profiles.json
docker compose up -d
```

```json
{
  "default": { "provider": "github", "auth": "https", "token": "github_pat_..." },
  "hosts": {
    "gitlab.com": { "provider": "gitlab", "auth": "https", "token": "glpat-..." },
    "git.example.com": { "provider": "gitea", "auth": "ssh", "key": "gitea_deploy", "known_hosts": "known_hosts" }
  },
  "projects": {
    "web-app": { "provider": "gitlab", "auth": "ssh", "key": "gitlab_deploy", "known_hosts": "known_hosts" }
  }
}
```

Supported: GitHub, GitLab, Gitea/Forgejo and self-hosted, over HTTPS tokens or SSH
keys, with several accounts and a per-workspace commit identity. HTTPS accounts
are host-scoped, so one forge's token is never offered to another; SSH keys are
picked by host through a generated wrapper. `secrets/` is mounted read-only at
`/run/secrets` and gitignored.

Unattended installs can point `GIT_PROFILES_FILE` at a ready manifest instead of
answering the prompts.

Everyone allowed in the workspace shares these credentials — that is the trust
model, not a bug. The agent can read `/run/secrets`; see
[docs/GIT.md](docs/GIT.md) for recipes, verification, rotation and the full
schema.

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
| `/system restart` | restart into a trial: the new state is live and the previous one is kept for rollback |
| `/system restart now` | restart without a trial; the current state becomes the rollback point |
| `/system update connector` | reinstall the pinned connector: stop, run `reset-plugin`, start in a trial |
| `/system update connector now` | same, without the trial |
| `/system update all` | drain all agents, then update the setup image through the updater sidecar; automatic rollback on failed health |
| `/system confirm` | commit the trial: this state becomes the new rollback point |
| `/system rollback` | restore the last committed **profile** state and restart (does not move the image) |
| `/system cancel` | abandon a pending update and unblock the bot; after acceptance it stops the updater job |
| `/system manage` | optional components (the design stack): a card with Enable/Disable/Port buttons |
| `/web` | a signed link into the web UI for the same sessions (bot chat only) |
| `/firewall` | native only: whether ufw lets the web UI through, and the `/firewall allow <port>` fix |

This table is the short version; the connector's
[`docs/COMMANDS.md`](https://github.com/vladtsvirko/dsh-telegram-connector/blob/main/docs/COMMANDS.md)
is the full command reference, and `/man` in the bot prints the same text.

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

`/system update connector` is the profile half of a host `reset-plugin` moved
into the bot: the supervisor stops the runtime, runs the entrypoint's own
`reset-plugin` (including its allow-builds and version compatibility handling),
then starts the runtime inside a trial. `now` skips the trial. If the reinstall
fails, the snapshot is restored before the runtime comes back. It reinstalls the
**pinned** connector version; it cannot move to a different setup tag.

`/system update all` is the image half: it drains every agent, asks the updater
sidecar to check out, build and start the latest **compatible setup tag**, and
reports the result to the control chat. The new entrypoint then installs the
connector tag derived from that setup version. If `DSH_UPDATER_TOKEN` is empty,
the command degrades to diagnostics and prints the host fallback
(`./update.sh --self-check` / `--self`).

Scopes:

| Operation | Scope | Rollback |
|---|---|---|
| `/system restart`, `/system update connector`, plugins | profile (`data/home/profiles/web`) | supervisor trial: Commit / Roll back / deadline |
| `/system update all` | setup checkout, DSH image, connector pin, profile snapshot | automatic on failed health; one previous image + one snapshot |
| `/system rollback` | profile only | does not move the image or the setup tag |

Sessions and the workspace are outside a profile trial. A change made directly
in `./data/home` while the container is stopped is outside any trial. Image
updates are reversible only through the automatic rollback or a manual host
procedure, not `/system rollback`. The full boundary is in
[`docs/LIMITS.md`](docs/LIMITS.md).

### Repairing and diagnosing

Re-running `./install.sh` is the repair path: it reads the deployment's `.env`,
keeps the values it already has (including the provider key) and re-applies the
units, the launcher and the runtime.

Two caveats before you rely on it:

- **A failed repair is not rolled back.** `.env`, the units and the profile
  config are written before the build and the health check, so a health failure
  exits with the deployment stopped and no previous state to return to. Copy
  `.env` (and, if in doubt, `data/`) first, or keep a recent
  `backups/self-*.tgz`.
- **The git author is preserved by default.** The prompt offers the identity
  already in `data/home/.gitconfig` (then the invoking user's, then the
  `sudo` user's), so a re-run keeps the agent's commits as they were; answer
  differently, or set `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`, only when you mean
  to change it.

Two commands answer "what is wrong right now?" without changing anything:

```sh
./install.sh --doctor          # or ./update.sh --doctor — same checks
./install.sh --doctor --fix    # repair the safe subset
./install.sh --rotate-key      # ask for a new provider key (otherwise: keep)
```

| Check | What it catches |
|---|---|
| `env-file` | a key assigned twice, CRLF line endings, a world-readable `.env` |
| `provider-key` | empty, truncated, or whitespace-bearing key — boots fine, fails every call |
| `credential-store` | a key saved in the web UI's Models page that outranks `.env` |
| `patch` | duplicated or unbalanced managed blocks in `cordis.patch.yml` |
| `registry` | the workspace document the web UI lists: unparseable, or naming a directory that vanished |
| `instance` | a second runtime over the same data directory |
| `version`, `service`, `web`, `data-owner` | half-applied updates, a stopped unit, an unreachable port, root-owned data |

Everything is repaired automatically after an install and after a successful
self-update, so the next repair does not have to find it.

### One runtime per data directory

The runtime takes a kernel lock on `data/.runtime.lock` and records
`data/.runtime.json` (`mode`, `pid`, `startedAt`). A second runtime over the
same `data` — a native service left running beside the Docker stack, or two
containers from two checkouts — waits 20 s and then refuses to start, naming the
holder. Do not force it: two runtimes over one data directory corrupt the
session store, poll the same bot token, and hold each other's session write
handles. That is what makes a session answer "held by another client" after a
restart, while the other runtime's web UI shows a different workspace list.

## Updating dsh

The normal path is `/system update all` in the bot: it drains every agent, asks
the updater sidecar, and the updater runs the same host update script. The host
commands remain the bootstrap, break-glass and deliberate manual path:

```sh
./update.sh --status     # setup/DSH version, container health, adapter, HTTP
./update.sh --doctor     # the same checks ./install.sh --doctor runs
./update.sh --self-check # latest compatible setup tag, change nothing
./update.sh --self       # latest compatible tag, build, health gate, rollback
./update.sh --plugin     # re-resolve the pinned Telegram adapter
```

`--self` checks out the target tag, builds while the old container runs, stops
`dsh` to freeze the state, snapshots `data/home` + `data/supervisor`, starts the
new image, and waits for health. On failure it restores the snapshot and the
previous image. One previous image and one `backups/self-*.tgz` are kept. The
rollback starts even when the published web port is broken, so Telegram can come
back.

`/system update all` does the same after draining all agents and reports the
result to the control chat. It is opt-in through the token: an empty
`DSH_UPDATER_TOKEN` leaves `/system update all` as a diagnostic that prints the
host fallback. Endpoint, modes, drain semantics and recovery are in
[docs/UPDATER.md](docs/UPDATER.md); version rules are in
[docs/VERSIONS.md](docs/VERSIONS.md).

**Plugin compatibility exemptions.** DSH mounts a plugin only when its declared
peer ranges match the runtime, or when the profile carries an *exact-version*
exemption in `<profile>/compatibility.json`:

```json
{ "dsh-telegram-connector@0.1.11": ["0.3.0"] }
```

The connector declares `>=0.1.0-rc.6 <0.3.0-0` for the DSH packages, so the
tested `0.2.1-rc.5` needs no exemption. `ensure_compat` checks this on every boot
and grants one only when the runtime is genuinely outside the declared ranges —
that is the unsafe, out-of-matrix case, and it logs a warning. A plugin upgrade
does not inherit the old exact-version key, which is why the boot check exists.

Do not treat an exemption as permission to cross a DSH line silently. The
version policy still requires the explicit incompatibility flag, and a DSH
outside the tested row is a compatibility event, not a normal update.

### Staying on latest safely

Each setup release bakes an exact DSH version and image tag. `--self-check` tells
you when a compatible tag moves; `--self` applies it with a health gate and a
one-step rollback. `ASSUME_YES=1` makes it unattended:

```cron
# Monday 04:17 — apply the latest compatible setup tag
17 4 * * 1 cd /home/YOU/docker && ASSUME_YES=1 ./update.sh --self >> /var/log/dsh-update.log 2>&1 || \
  echo "dsh update failed" | mail -s "dsh" you@example.com
```

### Other moving parts

| Layer | How it updates | Notes |
|---|---|---|
| dsh itself | setup release tag (`VERSION`, hardcoded Dockerfile/image tag) | The only version that matters for compatibility |
| Node base image | `docker compose build --pull` | Follows `24-bookworm-slim` within 24.x |
| pnpm | rebuild | `pnpm@11` floats within 11.x |
| Telegram connector | setup release tag (`VERSION`); `/system update connector` re-runs the boot install | It tracks the setup tag, not a floating branch; `--plugin` re-resolves the same pinned ref |
| updater sidecar | mounted `updater.mjs` reloads after an apply | Its image and OS packages need a host `docker compose build updater` |
| Other plugins | add via `dsh plugin`, pinned in the profile's `pnpm-lock.yaml` | Lives in `data/home`, survives rebuilds |
| Model names | `DSH_MODEL` in `.env` | Provider models change without any image change |

Nothing here auto-updates on its own: no watchtower, no floating tags. That is
deliberate — a container that silently changes the software running your shell is
a worse failure mode than a Monday morning bump you can roll back.

The updater sidecar is the one privileged component: it mounts the Docker socket
(no published port; reachable on the internal `ops` network with a bearer token,
plus `default`/`design` for egress) because rebuilding an image from inside the
runtime is impossible otherwise. The bot container never gets the socket.
`DSH_UPDATER_TOKEN` empty makes the sidecar refuse work, but it still runs with
the socket mounted; to remove that surface, stop and delete the `updater`
service (then `/system update all` reports the host fallback).

Telegram is still the only **normal** control path. If the bot cannot load, the
updater is wedged, Docker is down, or the host needs a `.env`/disk/ownership
change, there is no remote repair. Decide deliberately whether to keep a
break-glass host path; the full list is in [`docs/LIMITS.md`](docs/LIMITS.md).

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
| Connection refused on the web port after a container recreate | old images bound the first `hostname -I` address, which can be the internal `ops` network instead of the published default network | upgrade to a current release; the entrypoint now binds the default-route address and the updater verifies the published port |
| `docker compose ps` shows `(health: starting)` for a long time | the probe runs every 10s; the first ones land before the runtime is listening | `docker compose exec dsh /usr/local/bin/dsh-healthcheck; echo $?` — `0` means it is serving, whatever `ps` says |
| UI loads but keeps saying **reconnecting** | the browser dials the address the container advertises (`172.x`), which it cannot reach | set `DSH_PUBLIC_URL` to the root you actually use, e.g. `http://192.0.2.10:4310/` (a documentation address; use your own) |
| Bot silent after a dsh upgrade | adapter no longer mounts | re-grant the exemption, or move to the previous setup tag |
| Bot says `⛔ You are not authorized` | your id isn't in `allowedUserIds` | add it to `ALLOWED_USER_IDS` in `.env`, then `docker compose up -d dsh` |
| `no space left on device` | sessions + pnpm store in `/data/home` | prune old sessions, move `DSH_HOME` to a bigger volume |
| `/system update all` says updater unreachable | updater not running, token mismatch, or wrong `DSH_DOCKER_GID` | `docker compose ps updater`; `docker compose logs updater` |
| `/system update all` says the updater is disabled / answers `503` | `DSH_UPDATER_TOKEN` is empty | set it in `.env` and `docker compose up -d updater`; `canApply` is only ever false when the sidecar runs with `--no-apply` |
| Updater can't access Docker | `DSH_DOCKER_GID` does not match `getent group docker` | fix `.env`, `docker compose up -d updater` |
| Model calls fail after re-running the installer | the runtime prefers a key stored by the web UI over `.env` (or `.env` has two copies) | `./install.sh --doctor --fix`, then restart |
| Web UI lists no workspace after a restart, Telegram still does | the connector's bindings and the runtime's registry disagree | `/sync` in the group repairs it; the connector retries at boot |
| Telegram: "this session is held by another client" right after a restart | a second runtime over the same data directory holds the lock | `./install.sh --doctor` names it; stop the other mode, then `/system restart now` |
| Telegram: "this session is open in a web UI tab…" | a browser tab owns the session's write handle | the prompt is queued; tap **Take over** (restarts the runtime) or close the tab and resend |

If you are validating a release, [`docs/UAT.md`](docs/UAT.md) is the
step-by-step acceptance run for both modes.

## Removing it

```sh
./install.sh --uninstall --check     # the plan: what is stopped, what is kept
./install.sh --uninstall             # asks for confirmation
```

It stops and removes the compose stack (or disables the systemd units and their
`/usr/local/bin` launchers in native mode). It keeps `data/`, `.env` and
`backups/` so a reinstall picks up where the old one left off, and it never
deletes the checkout.

`--purge` also deletes those three, plus the images built for the deployment:

```sh
./install.sh --uninstall --purge
```

The last lines of the run print what still exists — the service user and the
checkout directory — and the exact command to remove each.

## Why not just a Unix user?

A user account is a *capability* boundary, not a containment one: the agent can
still read anything world-readable (`/etc`, other services' configs, loose `~/.ssh`),
shares the host PID namespace, is unlimited in CPU/RAM, and — the big one — has
unrestricted network egress. DSH's own sandbox is file-effects only and says so
explicitly. The container closes all of that by default instead of requiring you
to audit it.
