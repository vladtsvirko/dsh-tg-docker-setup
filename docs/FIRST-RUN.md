# First run

This is the short path from an empty server to an agent you can talk to from
Telegram **and** a browser, and then keep running. It assumes no prior knowledge
of DSH; the [README](../README.md) is the reference, and [UAT.md](UAT.md) is the
exhaustive acceptance run.

Budget ~20 minutes, most of it installing Node and the first boot.

## What you are installing

One runtime, two clients:

```
browser ──► http://<host>:4310 ──┐
                                 ├──► dsh (systemd service, user dsh)
Telegram ─► api.telegram.org ────┘        └── /srv/dsh/data (home + workspace)
```

Telegram and the web UI are views of the same runtime — not two installations.
You can start in one and continue in the other.

## Before you start

Have these ready; the installer asks for them:

| You need | Why |
|---|---|
| A Linux host (Ubuntu 24.04 / Debian 12 tested) with `sudo` | the installer adds Node 22, rootless Podman for the agent and the systemd units |
| A provider API key | the agent cannot answer without one |
| A Telegram bot token | from [@BotFather](https://t.me/BotFather) → `/newbot` |
| Privacy mode **off** for that bot | BotFather → `/setprivacy` → Disable, or it never sees plain messages in topics |
| Your numeric Telegram id | the allow-list is empty by default and refuses everyone; get it from [@userinfobot](https://t.me/userinfobot) |
| A group with **Topics** enabled, bot as admin with *Manage Topics* | a group is a workspace, a topic is a session |

The last one can be created after the install: the bot prints a one-tap
`?startgroup=` link, but it cannot create the group or enable Topics itself.

## 1. Install

```sh
wget -qO- https://raw.githubusercontent.com/vladtsvirko/dsh-tg-docker-setup/main/install.sh | bash
```

Run it as your normal user (with `sudo` available) or as root. It fetches the
newest release, asks the questions above, shows a plan, and only then changes
anything. One of its questions is a CPU/RAM share for the runtime (default 30%
of the machine, `0` = unlimited); it becomes `MemoryMax`/`CPUQuota`/`TasksMax`
on `dsh.service`.

Want to see the plan without touching the host?

```sh
wget -qO- https://raw.githubusercontent.com/vladtsvirko/dsh-tg-docker-setup/main/install.sh | bash -s -- --check
```

Or from a checkout: `git clone … && cd dsh-tg-docker-setup && ./install.sh`.

What it sets up that a hand-rolled `dsh` service does not: the updater token
(`/system update setup` needs it), the agent's git author, the profile repair pass,
and the wiring between the runtime and the updater. Prefer it over copying
`.env.example` by hand.

You can leave the bot token blank and get a **web-only** deployment. The adapter
is simply not installed; add the token to `.env` later and restart the service
(`sudo systemctl restart dsh.service`), and that boot installs it. The same
works in reverse: empty the token (or set `DSH_TELEGRAM_ENABLED=off`) to go back
to web-only without deleting anything.

At the end it prints the bare web origin and a health summary. If the health
check fails it stops there — and a failed install is **not** rolled back, so the
deployment may be partially applied. The journal is the next step, not a re-run:
see [If something is wrong](#if-something-is-wrong).

## 2. Open the web UI

The installer reads the runtime's log and prints the signed URL — it carries a
`?token=` and is the one the browser can use. If the summary shows the bare
origin instead (it could not read the log), that origin answers **401 on
purpose**; the signed link is in the runtime log:

```sh
journalctl -u dsh.service | grep 'dsh web:'
```

Open the signed URL. Two things to know:

- the token is a **credential** and a restart mints a new one — treat the link
  like a password;
- if you installed with `DSH_BIND_IP=127.0.0.1`, the port is host-only. Use
  `ssh -L 4310:127.0.0.1:4310 <host>` and open
  `http://127.0.0.1:4310/?token=…`; `DSH_PUBLIC_URL` must be set to
  `http://127.0.0.1:4310/` for that to work (see the README's knobs table).

The web UI is plain HTTP on the LAN. For anything beyond a trusted network, put
TLS in front and set `DSH_PUBLIC_URL` to the https root.

## 3. Bind a Telegram group

1. Open a private chat with your bot and send `/start`. This chat becomes the
   **control chat**: notices, update reports and system commands land here.
2. Send `/workspace new web-app`. The bot creates the directory, registers the
   workspace and prints a `t.me/…?startgroup=…` link.
3. Tap the link, pick a group, and add the bot. The group is now bound to that
   workspace.
4. In the group: enable **Topics**, and make the bot an admin with *Manage
   Topics* (plus *Change Info* if you want the group title to follow renames).
5. In **General**, send `/new` — or create a topic by hand and send a plain
   message in it. A topic is a session; the bot creates one per session.

Optional but recommended: create one empty topic and send `/dashboard` in it.
The management commands move there; session topics then take plain text (plus
`/commands`, `/skills`, `/run`, `/skill` and `//text`).

If the bot ignores plain messages, privacy mode is still on. If it says
`⛔ You are not authorized`, your id is missing from `ALLOWED_USER_IDS`.

## 4. Move between the two clients

One runtime means the handover is mostly automatic:

- **Telegram → browser:** `/web` in the bot chat prints a signed link into the
  same sessions. A session started in Telegram is an ordinary DSH session, so
  the web UI lists it.
- **Browser → Telegram:** a prompt sent in the browser is echoed into that
  session's topic (`💬 you (web) · …`) and answered in both places. A session
  that has no topic yet gets one from `/sync` in the group.
- **Both at once:** a session has **one live agent**. If a browser tab holds it,
  a Telegram prompt is refused and a **Take over** button appears; the message is
  queued, and tapping it restarts the runtime (releasing *every* handle, not just
  that session's) and then delivers it. Closing the tab is the cheaper move.

## 5. Buttons, and when to type

Most management is a typed command, but the common actions and the flows where
a mistake is expensive have buttons:

| Flow | What you get |
|---|---|
| `/dashboard` in the group | **➕ New session** · **🔄 Sync** · **📊 Status** · **📋 Sessions** |
| `/dashboard` in the bot chat | **📊 Status** · **🌐 Web link** · **⬆️ Update setup** · **♻️ Restart** · **🧩 Plugins** · **⚙️ Components** |
| Trial after a restart / connector update / plugin change | **✅ Commit** and **↩️ Roll back**, plus a deadline |
| `/system update setup` while draining | **✖ Cancel update** (after acceptance, `/system cancel` still stops the job) |
| `/system components` (design stack) | one row per component: Enable/Disable and Port |
| A session held by a browser tab | **↪️ Take over** |

Everything else is a command, and the bot is self-documenting: `/help` lists
what the current chat accepts, `/man` prints the full manual, and
`<command> --help` explains one command. The same text is in the connector's
[COMMANDS.md](https://github.com/vladtsvirko/dsh-telegram-connector/blob/main/docs/COMMANDS.md).
The bot also registers its command menu with Telegram, so the `/` list in the
app is populated for the chat you are in.

## 6. Day two, over SSH

The normal control path is Telegram. SSH is for the things a bot cannot do:
editing `.env`, changing the port or bind address, changing the resource share,
and recovering from a dead runtime. [LIMITS.md](LIMITS.md) is the exact boundary.

```sh
# what is installed, and is it healthy
./update.sh --status
./install.sh --doctor            # add --fix to repair the safe subset

# update the whole setup (the bot does this too, via /system update setup)
./update.sh --check         # what would change
sudo ./update.sh --apply          # check out, install, health gate, automatic rollback

# change a setting: edit .env, then restart (the unit re-reads it on start)
sudo systemctl restart dsh.service
```

`update.sh --apply` needs root (`sudo ./update.sh --apply`); it writes the
root-owned checkout and restarts `dsh.service`.

**Add a project.** Create the workspace (`/workspace new <name>`), then clone
into it *as the service user*, where the generated git credentials apply:

```sh
sudo -u dsh env HOME=/srv/dsh/data/home \
  git clone git@github.com:you/private-repo.git /srv/dsh/data/workspace/<name>
```

The same works from the agent's bash tool inside the runtime. Private
repositories need a token or SSH key in `secrets/git/profiles.json`; [GIT.md](GIT.md)
has the manifest and the SSH recipe.

**Add a plugin.** Prefer `/plugin add <spec>` in the bot chat: it inspects the
package, asks for confirmation, and opens a rollback window. On the host, run
the same command as the service user, then restart:

```sh
cd /srv/dsh/data/workspace
sudo -u dsh env HOME=/srv/dsh/data/home DSH_HOME=/srv/dsh/data/home \
  DSH_WORKSPACE=/srv/dsh/data/workspace dsh plugin --profile web add <spec>
```

`/system restart` (or `sudo systemctl restart dsh.service`) applies it — and pnpm
may block a git package's build script, which `/plugin approve` handles in the
chat.

## If something is wrong

| Symptom | First thing to run |
|---|---|
| install ended before the summary | `journalctl -u dsh.service -n 100` |
| web UI loads but reconnects forever | set `DSH_PUBLIC_URL` to the URL you actually open, then `sudo systemctl restart dsh.service` |
| bot silent | check `ALLOWED_USER_IDS`, privacy mode, and `journalctl -u dsh.service \| grep -i telegram` |
| model calls fail | `./install.sh --doctor` (a key saved in the web UI can outrank `.env`) |
| an update went wrong | `/system status`, then [UPGRADE.md](UPGRADE.md) |

## Where to read next

- [README.md](../README.md) — every knob and the operating reference.
- [UPGRADE.md](UPGRADE.md) — upgrades, the health gate, and the rollback drill.
- [GIT.md](GIT.md) — repository access for the agent.
- [HOST.md](HOST.md) — the host deployment: units, containers, resource limits, update authority.
- [LIMITS.md](LIMITS.md) — what still needs a host shell, and why.
