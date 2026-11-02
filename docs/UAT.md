# Acceptance run: Docker host and native VM

These steps were written for `v0.2.1-rc.2-0.8.0`; if you are accepting a later
tag, substitute it everywhere below.

Two runs, one per mode. Each takes ~20 minutes. The point is not to see it work
once, but to see the **recovery** paths work: a trial that commits, a trial that
rolls back by itself, an update that can be cancelled, and an uninstall that
leaves nothing running.

Write down the step number with anything unexpected, and keep the output of
`/system status`, `docker compose logs dsh --tail=100` (or
`journalctl -u dsh.service -n 100`) and the terminal transcript.

---

## A. Docker mode (the machine you already run)

### A0. Before you start

- [ ] `./install.sh --check` prints a plan and stops.
- [ ] the plan shows `mode: docker`, the right port, and your admin id
- [ ] `docker compose ps` in the current deployment shows `dsh` healthy

### A1. Install a second deployment from the new tag

Do not touch the running one. Use another directory and port:

```sh
git clone https://github.com/vladtsvirko/dsh-tg-docker-setup /tmp/uat-docker
cd /tmp/uat-docker && git checkout v0.2.1-rc.2-0.8.0
./install.sh --dir /tmp/uat-docker --check      # read the plan first
./install.sh --dir /tmp/uat-docker
```

Answers to have ready: a **new** bot token (a second bot, so the two deployments
never poll the same token), its group with Topics + the bot as admin, your user
id, your provider key, a free port (e.g. 4320).

- [ ] the installer ends with `==> installed: 0.2.1-rc.2-0.8.0 (docker mode)`
- [ ] the summary prints `web: http://<ip>:<port>/ (send /web …)` and the key line
      says either `set` or how to add it
- [ ] it warns about web UI exposure when binding a LAN address

### A2. First contact in Telegram

- [ ] send `/start` to the new bot: it answers with the help index
- [ ] `/workspace new uat` prints a `?startgroup=` link
- [ ] tap it, add the bot to a new group with Topics enabled: the group gets a
      dashboard
- [ ] `/new` in the group creates a topic; a message in it gets a streamed answer
- [ ] `/system status` shows: version `0.6.0`, the admin line, `web: 127.0.0.1:<port> answered …`,
      `key: set`, `last agent error: none`

### A3. The two surfaces, both directions

- [ ] send `/web` in the bot chat: a signed link, and the text says it is a
      credential
- [ ] open it in a browser on the LAN: the same topics are there
- [ ] send a prompt from the browser, in the topic of a session: **the echo
      (`💬 you (web) · …`) and then the answer appear in Telegram, in that
      order, as two messages**
- [ ] send a prompt in Telegram: it appears in the browser and the answer
      streams in both
- [ ] with the browser open on a session, send a prompt from Telegram: the bot
      answers "this session is open in a web UI tab…" with a **Take over**
      button, and says the message is queued
- [ ] tap **Take over**: the runtime restarts, the queued message is delivered,
      and the session answers again in Telegram

### A4. A trial that commits

- [ ] `/system restart` → the card has **Commit** and **Roll back**, and a
      deadline
- [ ] `/system confirm` → the card closes; `/system status` shows no open trial
- [ ] the bot answered a message after the restart (nothing was lost)

### A5. A trial that rolls back by itself

- [ ] `/system restart` → **do not confirm**
- [ ] at the deadline the chat says `Rolled back to the last committed state: no
      confirmation within N minutes.`
- [ ] `/system status` shows no trial and `last event: rollback`

### A6. An update, and a cancel

- [ ] `/system update all` → drains, then either finishes (`✅ setup update
      finished`) or reports why not. On this tag there is no newer compatible
      release, so `no compatible tag after …` is the correct answer
- [ ] start `/system update all` again and press **✖ Cancel** during the drain:
      the card closes and normal messages work immediately after
- [ ] `/system cancel` in the chat does the same thing as the button

### A7. Component control (only if you installed the design stack)

- [ ] `/system manage` lists the components with their state
- [ ] change the Penpot port: the card reports done, the stack answers on the new
      port, and `/system status` still shows the runtime healthy
- [ ] disable it: the stack stops, the runtime keeps working

### A8. Uninstall

```sh
./install.sh --uninstall --check     # what it will stop and what it keeps
./install.sh --uninstall             # asks for confirmation
```

- [ ] the compose stack is gone (`docker compose ps` is empty)
- [ ] `data/`, `.env` and `backups/` are still there
- [ ] the last lines say which user and directory remain, and how to remove them
- [ ] `./install.sh --uninstall --purge` on the *uat* directory removes those too

---

## B. Native mode (the spare VM)

Use a fresh Debian/Ubuntu VM (2 CPU, 4 GB). Root access, network, nothing else.

### B0. Prerequisites

- [ ] Node ≥ 22 present **or** documented as the one thing to install
      (`node -v`; the installer needs it before it starts)
- [ ] a third bot token, and its group with Topics + the bot as admin

### B1. Install

```sh
git clone https://github.com/vladtsvirko/dsh-tg-docker-setup /srv/uat-setup
cd /srv/uat-setup && git checkout v0.2.1-rc.2-0.8.0
sudo ./install.sh --mode native --dir /srv/dsh --check
sudo ./install.sh --mode native --dir /srv/dsh
```

- [ ] `--check` shows `tier: sandbox`, `user: dsh`, `data: /srv/dsh/data`
- [ ] the installer installs `dsh` **and** `pnpm` (it says so)
- [ ] it ends with `==> installed: 0.2.1-rc.2-0.8.0 (native mode)`
- [ ] `systemctl status dsh.service` is `active (running)`
- [ ] `journalctl -u dsh.service -n 30` shows the runtime listening and the
      connector connected

### B2. The same acceptance, shorter

- [ ] `/system status` in the bot chat: version, admin, `web`, `key`, supervisor
- [ ] `/web` gives a link to the VM's address, and it opens from your laptop
- [ ] a prompt in a topic gets a streamed answer
- [ ] a prompt from the browser mirrors into the topic (echo, then answer)

### B3. Update and rollback in native mode

This is the mode whose update path was broken before this release.

- [ ] `/system restart` → confirm → no trial left
- [ ] `/system restart` → roll back → `Rolled back to the last committed state`
- [ ] `/system update connector` → the connector reinstalls and the bot returns
- [ ] after the restart, `journalctl -u dsh.service -n 50` has no
      `already owned by an active write handle`

### B4. Uninstall

```sh
sudo ./install.sh --uninstall --dir /srv/dsh
```

- [ ] `systemctl status dsh.service` says it does not exist
- [ ] `/usr/local/bin/dsh-*` launchers are gone
- [ ] `/srv/dsh/data` is still there; `--purge` removes it

---

## What to send back

For each failed checkbox: the step, what you expected, what happened, and:

```sh
./update.sh --status
docker compose logs --tail=100 dsh     # or: journalctl -u dsh.service -n 100
```

Do not paste `.env`. `/system status` and the logs never include the bot token or
the provider key.
