# DSH setup

One host, one agent runtime, two clients:

```
  LAN browser ──► <host>:4310 ──┐
                                ├──► dsh (systemd service) ──► agents / tools / sessions
  Telegram ────► api.telegram.org┘             │
                                               └── /srv/dsh/data (home + workspace)
```

The runtime is an unprivileged **systemd service** on this host. The agent runs
as a service user that can read what that user can read — there is no container
boundary — and the installer, the units and the checkout are root-owned, so the
runtime cannot rewrite its own control plane. What that means, and the ways
around it, is [docs/HOST.md](docs/HOST.md).

**First time here?** [docs/FIRST-RUN.md](docs/FIRST-RUN.md) is the short
walkthrough: one command, the web link, the Telegram group, and how to move a
session between the two.

## Files

| File | Purpose |
|---|---|
| `install.sh` | One-command installer: interactive, `--check` for a dry run, `--doctor [--fix]` to diagnose/repair |
| `update.sh` | Check / apply / roll back setup updates |
| `entrypoint.sh` | Boot preparation (profile, plugins, provider, git), then `exec dsh` under the supervisor |
| `supervisor.mjs` | Owns restarts and the profile snapshot; trial restarts with automatic rollback |
| `updater.mjs` | The privileged updater service behind `/system update all` (loopback only) |
| `healthcheck.sh` | The probe systemd and the updater run |
| `.env.example` | Every knob, with comments |
| `install.example.env` | Every answer `install.sh --config` accepts |
| `scripts/repair.sh` | The health check `install.sh --doctor` and `update.sh --doctor` run |
| `scripts/credentials.mjs` | Reads and reconciles `data/home/.credentials.yaml` without printing a secret |
| `scripts/git-manifest.mjs` | Builds or merges `secrets/git/profiles.json` from the installer's accounts |
| `components.json` | Optional components (the Penpot design stack) |
| `design/` | Penpot compose stack + the `penpot` CLI for design work (`--design docker`) |
| `docs/FIRST-RUN.md` | The guided first run |
| `docs/HOST.md` | The host deployment: layout, tiers, resource limits, security boundary |
| `docs/VERSIONS.md` | Version scheme, release coupling and update rules |
| `docs/UPGRADE.md` | Upgrading, the health gate vs. a trial, and the rollback drill |
| `docs/SELF-UPDATE.md` | `update.sh --self` in detail |
| `docs/UPDATER.md` | The privileged updater service |
| `docs/GIT.md` | Repository access: HTTPS tokens and SSH keys, per host and workspace |
| `docs/UAT.md` | The acceptance run for a release |
| `docs/LIMITS.md` | What still needs a host shell, and why |
| `docs/UPSTREAM-WATCH.md` | The daily check for a new DSH release candidate |

## Before you start

The installer cannot create these; have them ready or the first run ends with a
working runtime and no bot.

| You need | Why | Where |
|---|---|---|
| Ubuntu 24.04 / Debian 12 (or any systemd distro with Node ≥ 22.19) | the runtime | your VPS or machine |
| `sudo` (the installer writes systemd units) | the deployment | — |
| A provider API key | the agent cannot answer without one | the installer asks for it |
| A bot token | the Telegram surface | [@BotFather](https://t.me/BotFather) → `/newbot` |
| **Privacy mode off** for that bot | otherwise it never sees plain messages in topics, which is the whole input path | `/setprivacy` → Disable |
| A group with **Topics enabled**, bot as admin with *Manage Topics* | groups are workspaces, topics are sessions | group settings |
| Your numeric Telegram id | the allow-list is empty by default and the bot refuses everyone else | [@userinfobot](https://t.me/userinfobot) |

The bot cannot create the group; `/workspace new` prints a one-tap
`?startgroup=` link, and you create it. Docker is only needed if you choose the
optional Penpot design stack.

## Install

### From the internet, on a fresh machine

One file, no checkout. It installs git and Node 22 if missing, then the
systemd units:

```sh
wget -qO- https://raw.githubusercontent.com/vladtsvirko/dsh-tg-docker-setup/main/install.sh | bash
```

Run it as a normal user with `sudo` available, or as root. It:

1. says what it is going to fetch (the newest release tag) and where
   (`/opt/dsh-setup` as root, `~/dsh-setup` otherwise),
2. downloads that release into a git checkout — which is what makes
   `update.sh --self` work later,
3. asks the questions, then shows the plan and asks before changing anything:
   `Proceed? [Y/n]`,
4. asks what the agent should commit as, and optionally for one or more git
   accounts (GitHub, GitLab, Gitea/Forgejo, self-hosted; HTTPS token or SSH
   key) — stored in `<dir>/secrets/git/profiles.json`, mode 0600,
5. writes `/srv/dsh/.env`, the two systemd units, the `/usr/local/bin`
   launchers and the profile, then waits for the health check.

`--check` shows the whole plan first, including what would be installed:

```sh
wget -qO- https://raw.githubusercontent.com/vladtsvirko/dsh-tg-docker-setup/main/install.sh | bash -s -- --check
```

Unattended, with every answer in a file (see `install.example.env`):

```sh
curl -fsSL …/install.sh | bash -s -- --yes --config answers.env
```

The release the one-liner fetches is the newest tag; pin it with `--ref
v0.2.1-rc.5-0.8.2`. `--dir` moves the deployment directory (default `/srv/dsh`).
If Node is already installed and you would rather manage it yourself, pass
`--no-deps`: the installer then fails with the exact command to run instead of
touching apt.

`--check` needs `git` to fetch the release it is going to describe; on a host
without git it can only say so and exit.

### From a checkout

```sh
git clone https://github.com/vladtsvirko/dsh-tg-docker-setup
cd dsh-tg-docker-setup
./install.sh --check        # the full plan, nothing changed
./install.sh                # interactive: port, key, bot token, admin, git
```

### Tiers

`--tier sandbox` (default) is the hardened systemd unit: `ProtectSystem=strict`,
`ProtectHome=yes`, `NoNewPrivileges`, writes only under the data directory.
`--tier privileged` adds the `docker` group to the service user, i.e. gives the
agent Docker access (root-equivalent) — only for deployments that need it.

### Resource limits

The installer asks for a CPU/RAM share and proposes **30% of the machine**:

```
CPU/RAM limit for the runtime, percent of this machine (0 = unlimited) [30]:
```

It becomes `MemoryMax`/`CPUQuota` (and `TasksMax=512`) on `dsh.service`, so a
runaway command cannot take the host down. `0` writes no limits. A repair keeps
the deployed value; `DSH_RESOURCE_PERCENT` in `.env` is the same knob.

## First run

Use the installer, then:

1. **Open the web UI.** The installer reads the runtime's log and prints the
   signed URL (it carries a `?token=`). If it could not read the log, the bare
   origin it falls back to answers **401** on purpose — the signed link is in
   `journalctl -u dsh.service | grep 'dsh web:'`. That URL is a credential, and
   a restart mints a new one.
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

## Data layout

```
/srv/dsh                the deployment checkout (a git clone at a release tag)
/srv/dsh/.env           port, tokens, resource share — 0640 root:dsh
/srv/dsh/data/home      DSH_HOME — profile, sessions, connector state
/srv/dsh/data/workspace the agent's working directory
/srv/dsh/data/supervisor supervisor state and the stable profile snapshot
/srv/dsh/secrets/git    repository credentials, 0600/0700
/usr/local/bin/dsh-*    symlinks into the checkout (entrypoint, supervisor,
                        healthcheck, updater, git credentials, penpot)
```

`/srv/dsh` is root-owned; the data directory is owned by the service user. That
is why an update can be a `git checkout` without leaving root-owned profile
files behind. Back up `data/home` if you care about session history (it is the
agent's memory), and `data/workspace` if you care about its files.

## Knobs that matter

| Setting | Why |
|---|---|
| `DSH_PROVIDER` / `DSH_MODEL` | Model route. Default `opencode-go` / `deepseek-v4.1-flash`; `deepseek-official` / `deepseek-v4-flash` also supported. |
| `OPENCODE_GO_API_KEY` | Key for the default route. The entrypoint warns at boot if the matching variable is empty. |
| `DSH_RESOURCE_PERCENT` | CPU/RAM share of the machine (`30` default, `0` = unlimited). Written into the unit as `MemoryMax`/`CPUQuota`/`TasksMax`. |
| `DSH_PUBLIC_URL` | The root the browser dials for API + WebSocket, and the only authority trusted for the web app. Defaults to `http://$DSH_BIND_IP:$DSH_PORT/`; set it when you use a hostname, proxy or VPN name. With `DSH_BIND_IP=127.0.0.1` you **must** set it. |
| `DSH_BIND_IP` | The interface the web UI binds. `127.0.0.1` = host-only, normally via `ssh -L <port>:127.0.0.1:<port>`; also set `DSH_PUBLIC_URL=http://127.0.0.1:<port>/`, otherwise the UI advertises an address the browser cannot reach. Never bind `0.0.0.0` — the UI drives a shell. |
| `ALLOWED_USER_IDS` | Who may use the bot. Empty rejects everyone (including you). |
| `DSH_ADMIN_USER_ID` | The one account allowed to restart, update, roll back, install plugins and create/bind workspaces. Blank means the control-chat owner. |
| `DSH_TELEGRAM_ENABLED` | `auto` / `on` / `off`. Leave `auto`: the adapter is on exactly when a token is set. |
| `DSH_TRIAL_SECONDS` | Rollback window for a trial, default `300` (5 min). |
| `DSH_BOOT_GRACE_SECONDS` | How long a trial runtime may stay up without checking in, default `120`. |
| `DSH_UPDATE_TIMEOUT_SECONDS` | Deadline for a supervisor job and for an updater apply, default `900`; the updater's own fallback is `1800`. |
| `DSH_UPDATER_TOKEN` | Bearer token for the updater service. Empty makes it refuse work; `/system update all` then prints the host fallback. Treat it as a root credential. |

## Versioning and compatibility

The connector and the setup ship as **one tag**:

```
<dsh-version>-<major>.<minor>.<patch>      v0.2.1-rc.5-0.8.2
         DSH part          product part
```

- The DSH part is the exact tested runtime. It is derived from `VERSION` and
  installed with `npm install -g @deepseek-ai/dsh@<dsh part>`; there is no
  `DSH_VERSION` `.env` knob.
- Product `0.x` is compatible. A new major is a break. The product part resets to
  `0.0.0` when the pair moves to a new DSH line.
- Same DSH part and same product major may jump (`0.1.1 → 0.4.2`).
- Crossing a DSH line or product major requires the explicit
  `--i-know-versions-are-incompatible`; neither `/system` nor a scheduled update
  crosses on its own.
- Tags are immutable. The setup `VERSION` and the connector `package.json` must
  carry the same version; each repository's CI checks its own half, and a setup
  tag build also proves the connector tag exists.

The entrypoint does not float the connector. It forces
`github:vladtsvirko/dsh-telegram-connector#v${DSH_SETUP_VERSION}` (the setup tag)
and reinstalls when that ref changes. Therefore:

- a setup release **needs** a matching connector tag — even when only setup code
  changed;
- a connector change you want a deployment to use **needs** a setup release with
  the same version;
- `/system update connector` reinstalls the **pinned** connector; it does not
  select a newer connector tag.

The full policy, release checklist and coupling rules are in
[`docs/VERSIONS.md`](docs/VERSIONS.md). Inside the bot, `/about` reports the
connector version, runtime version and updater state.

## Choosing the connector

`DSH_TELEGRAM_PLUGIN` decides which plugin gets installed and mounted. Empty
(the default) means this setup's connector, pinned to the setup version:

| Ref | Model |
|---|---|
| *(empty)* | group = workspace, topic = session, control chat = private, version = setup tag |
| `github:ben7am1n/dsh-telegram` | one chat = one session, flat |

The package name is derived from the ref (or set `DSH_TELEGRAM_PACKAGE`), because
the patch row, the install check and the version exemption all key off it. After
changing it, run `sudo ./update.sh --plugin` once — otherwise the previous
plugin stays installed and two pollers fight over the same token.

## Operating it

```sh
journalctl -u dsh.service -f                 # runtime + adapter logs
systemctl status dsh.service dsh-updater.service
sudo -u dsh /usr/local/bin/dsh-healthcheck   # exit 0 = serving
sudo systemctl restart dsh.service           # after editing .env
./update.sh --status                         # setup/dsh versions, services, web
```

**Change the allowlist / model after first boot:** edit `/srv/dsh/.env`
(`ALLOWED_USER_IDS`, `DSH_MODEL`, `OPENCODE_GO_API_KEY`/`DEEPSEEK_API_KEY`), then
`sudo systemctl restart dsh.service`.

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
- The outbox keeps one queue per group, paced per bot, and shows a single status
  line while it waits. When every bot is saturated, the owner gets a digest in
  the bot chat.
- Messages are delivered exactly once when the send is acknowledged; the only
  loss window is a crash between Telegram accepting and the acknowledgement.

## Repository access (git)

Private repositories get credentials from one JSON manifest: a `default`
account, host-scoped `hosts` (one per forge), and optional per-workspace
`projects`. The installer fills it in — one account, or several — and a re-run
merges new accounts instead of replacing the file. To do it by hand:

```sh
cp -r secrets.example secrets
chmod -R go-rwx secrets
$EDITOR secrets/git/profiles.json
sudo systemctl restart dsh.service
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
picked by host through a generated wrapper. `secrets/` is gitignored.

Unattended installs can point `GIT_PROFILES_FILE` at a ready manifest instead of
answering the prompts. Everyone allowed in the workspace shares these
credentials — that is the trust model, not a bug; see
[docs/GIT.md](docs/GIT.md) for recipes, verification, rotation and the full
schema.

## Restarts and rollback

The runtime runs under `supervisor.mjs` (entrypoint → supervisor → `dsh`). The
supervisor is the only component that does not load plugins, which is the whole
point: a plugin that breaks startup must not be able to take the recovery path
down with it. It keeps a copy of the profile directory in
`./data/supervisor/stable` and can put it back without a network or a package
manager.

From the bot chat:

| Command | Effect |
|---|---|
| `/system restart` | restart into a trial: the new state is live and the previous one is kept for rollback |
| `/system restart now` | restart without a trial; the current state becomes the rollback point |
| `/system update connector` | reinstall the pinned connector: stop, run `reset-plugin`, start in a trial |
| `/system update connector now` | same, without the trial |
| `/system update all` | drain all agents, then update the setup through the updater; automatic rollback on failed health |
| `/system confirm` | commit the trial: this state becomes the new rollback point |
| `/system rollback` | restore the last committed **profile** state and restart (does not move the checkout) |
| `/system cancel` | abandon a pending update and unblock the bot; after acceptance it stops the updater job |
| `/system manage` | optional components (the design stack): a card with Enable/Disable/Port buttons |
| `/web` | a signed link into the web UI for the same sessions (bot chat only) |
| `/firewall` | whether ufw lets the web UI through, and the `/firewall allow <port>` fix |

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

If the service restarts mid-trial, the deadline is persisted: a trial still
inside its window resumes, an expired one is rolled back before the runtime
starts. The supervisor sends the rollback notice itself, since it knows the bot
token and the control chat id from `bindings.json`; the trial announcement comes
from the connector once it is up.

`/system update connector` is the profile half of a host `reset-plugin` moved
into the bot: the supervisor stops the runtime, runs the entrypoint's own
`reset-plugin` (including its allow-builds and version compatibility handling),
then starts the runtime inside a trial. `now` skips the trial. If the reinstall
fails, the snapshot is restored before the runtime comes back.

`/system update all` is the checkout half: it drains every agent, asks the
updater service to check out, install and start the latest **compatible setup
tag**, and reports the result to the control chat. If `DSH_UPDATER_TOKEN` is
empty, the command degrades to diagnostics and prints the host fallback
(`./update.sh --self-check` / `--self`).

Scopes:

| Operation | Scope | Rollback |
|---|---|---|
| `/system restart`, `/system update connector`, plugins | profile (`data/home/profiles/web`) | supervisor trial: Commit / Roll back / deadline |
| `/system update all` | setup checkout, DSH install, connector pin, profile snapshot | automatic on failed health; one previous checkout + one snapshot |
| `/system rollback` | profile only | does not move the checkout or the setup tag |

Sessions and the workspace are outside a profile trial. A change made directly
in `./data/home` while the service is stopped is outside any trial. The full
boundary is in [`docs/LIMITS.md`](docs/LIMITS.md).

### Repairing and diagnosing

Re-running `./install.sh` is the repair path: it reads the deployment's `.env`,
keeps the values it already has (including the provider key and the resource
share) and re-applies the units, the launcher and the runtime.

Two caveats before you rely on it:

- **A failed repair is not rolled back.** `.env`, the units and the profile
  config are written before the health check, so a health failure exits with the
  service stopped and no previous state to return to. Copy `.env` (and, if in
  doubt, `data/`) first, or keep a recent `backups/self-*.tgz`.
- **The git author is preserved by default.** The prompt offers the identity
  already in `data/home/.gitconfig` (then the invoking user's, then the `sudo`
  user's), so a re-run keeps the agent's commits as they were.

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
`data/.runtime.json` (`mode`, `pid`, `startedAt`). A second runtime over the same
`data` — a hand-started `dsh` beside the service, or two checkouts pointing at
one directory — waits 20 s and then refuses to start, naming the holder. Do not
force it: two runtimes over one data directory corrupt the session store, poll
the same bot token, and hold each other's session write handles. That is what
makes a session answer "held by another client" after a restart, while the other
runtime's web UI shows a different workspace list.

## Updating dsh

The normal path is `/system update all` in the bot: it drains every agent, asks
the updater service, and the updater runs the same host update script. The host
commands remain the bootstrap, break-glass and deliberate manual path:

```sh
./update.sh --status     # setup/DSH version, service health, adapter, HTTP
./update.sh --doctor     # the same checks ./install.sh --doctor runs
./update.sh --self-check # latest compatible setup tag, change nothing
./update.sh --self       # latest compatible tag, health gate, rollback
./update.sh --plugin     # re-resolve the pinned Telegram adapter
```

`--self` snapshots `data/home` + `data/supervisor`, checks out the target tag,
installs the matching `dsh` globally, re-runs the entrypoint's prepare step as
the service user, restarts `dsh.service` and waits for health. On failure it
restores the snapshot and the previous tag. One `backups/self-*.tgz` is kept.

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

Each setup release derives its DSH version from `VERSION`. `--self-check` tells
you when a compatible tag moves; `--self` applies it with a health gate and a
one-step rollback. `ASSUME_YES=1` makes it unattended:

```cron
# Monday 04:17 — apply the latest compatible setup tag
17 4 * * 1 cd /srv/dsh && ASSUME_YES=1 ./update.sh --self >> /var/log/dsh-update.log 2>&1 || \
  echo "dsh update failed" | mail -s "dsh" you@example.com
```

### Other moving parts

| Layer | How it updates | Notes |
|---|---|---|
| dsh itself | setup release tag (`VERSION`, DSH part) | The only version that matters for compatibility |
| Node | host package manager | ≥ 22.19; the installer uses NodeSource when it must |
| Telegram connector | setup release tag (`VERSION`); `/system update connector` re-runs the boot install | It tracks the setup tag, not a floating branch |
| updater | checkout, restarted by systemd | Its code is the mounted checkout |
| Other plugins | add via `/plugin add` or `dsh plugin`, pinned in the profile's `pnpm-lock.yaml` | Lives in `data/home`, survives updates |
| Model names | `DSH_MODEL` in `.env` | Provider models change without any install change |

Nothing here auto-updates on its own: no floating tags, no watchtower. A Monday
morning bump you can roll back beats software that changes under you.

Telegram is still the only **normal** control path. If the bot cannot load, the
updater is wedged, or the host needs a `.env`/disk/ownership change, there is no
remote repair. Decide deliberately whether to keep a break-glass host path; the
full list is in [`docs/LIMITS.md`](docs/LIMITS.md).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Service restarts, log shows permission denied on `data/` | data owned by root | `sudo chown -R dsh:dsh /srv/dsh/data`, `sudo systemctl restart dsh.service` |
| `dsh.service` fails at boot | bad unit or missing Node | `journalctl -u dsh.service -n 60`; `./install.sh --doctor` |
| `adapter install failed` in log | no egress during first boot, or the version gate | `journalctl -u dsh.service \| grep -i plugin`; `sudo ./update.sh --plugin` |
| Web UI 200 but API calls 403 | opened the bare origin instead of the `?token=` URL | use the URL from the log, or set `DSH_PUBLIC_URL` |
| `failed to bind …: cannot assign requested address` | `DSH_BIND_IP` isn't an address of this host | fix `.env`, `sudo systemctl restart dsh.service` |
| UI loads but keeps saying **reconnecting** | the browser dials an address it cannot reach | set `DSH_PUBLIC_URL` to the root you actually use |
| Bot silent after a dsh upgrade | adapter no longer mounts | re-grant the exemption, or move to the previous setup tag |
| Bot says `⛔ You are not authorized` | your id isn't in `allowedUserIds` | add it to `ALLOWED_USER_IDS` in `.env`, then restart |
| `no space left on device` | sessions + pnpm store in `data/home` | prune old sessions, move the data directory |
| `/system update all` says updater unreachable | updater not running, or token mismatch | `systemctl status dsh-updater.service`; `journalctl -u dsh-updater.service` |
| Model calls fail after re-running the installer | the runtime prefers a key stored by the web UI over `.env` (or `.env` has two copies) | `./install.sh --doctor --fix`, then restart |
| Web UI lists no workspace after a restart, Telegram still does | the connector's bindings and the runtime's registry disagree | `/sync` in the group repairs it; the connector retries at boot |
| Telegram: "this session is held by another client" right after a restart | a second runtime over the same data directory holds the lock | `./install.sh --doctor` names it; stop the other one, then `/system restart now` |
| Telegram: "this session is open in a web UI tab…" | a browser tab owns the session's write handle | the prompt is queued; tap **Take over** or close the tab |

If you are validating a release, [`docs/UAT.md`](docs/UAT.md) is the
step-by-step acceptance run.

## Removing it

```sh
./install.sh --uninstall --check     # the plan: what is stopped, what is kept
./install.sh --uninstall             # asks for confirmation
```

It disables and removes the systemd units and their `/usr/local/bin` launchers.
It keeps `data/`, `.env` and `backups/` so a reinstall picks up where the old one
left off, and it never deletes the checkout.

`--purge` also deletes those three:

```sh
./install.sh --uninstall --purge
```

The last lines of the run print what still exists — the service user and the
checkout directory — and the exact command to remove each.

## The security boundary

The runtime is an unprivileged Unix user, not a container. It can read anything
that user can read (`/etc`, other projects under `/srv`, the host network), and
the systemd unit narrows writes to the data directory. The agent cannot modify
the deployment checkout or the units, and cannot become root
(`NoNewPrivileges`). It shares the service user with the connector, so it can
read the bot and updater tokens; the updater token only accepts a release
target, but treat it as a root credential. If the host also holds other tenants'
secrets, use a VM; the details, the trade-offs and the tiers are in
[docs/HOST.md](docs/HOST.md).
