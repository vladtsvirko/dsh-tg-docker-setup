# Acceptance run: the native install

These steps were written for `v0.2.1-rc.5-0.14.7`; if you are accepting a later
tag, substitute it everywhere below.

One run, ~20 minutes. The point is not to see it work once, but to see the
**recovery** paths work: a trial that commits, a trial that rolls back by
itself, an update that can be cancelled, and an uninstall that leaves nothing
running.

Write down the step number with anything unexpected, and keep the output of
`/system status`, `journalctl -u dsh.service -n 100` and the terminal
transcript.

---

## 0. Before you start

Use a fresh Debian/Ubuntu VM (2 CPU, 4 GB). Root access, network, nothing else.
Podman is installed for the agent; the optional design stack uses it too
in step 7.

- [ ] Node **not** installed: the installer must install 22 from NodeSource
      itself and say so in the plan (`deps: installs Node 22 …`)
- [ ] `git` available: the `--check` bootstrap needs it to fetch the preview
      (the real install would add it)
- [ ] a **new** bot token (separate from any existing deployment, so they never
      poll the same token), its group with Topics + the bot as admin, your user
      id, your provider key, a free port (e.g. 4320)

## 1. Install

Install the way a stranger would — one downloaded file:

```sh
wget -qO- https://raw.githubusercontent.com/vladtsvirko/dsh-tg-docker-setup/v0.2.1-rc.5-0.14.7/setup.sh | sudo bash -s -- --check --dir /srv/dsh
wget -qO- https://raw.githubusercontent.com/vladtsvirko/dsh-tg-docker-setup/v0.2.1-rc.5-0.14.7/setup.sh | sudo bash -s -- --dir /srv/dsh
```

All `./setup.sh` and `./setup.sh update` checks below run from `/srv/dsh`.

- [ ] the first line prints what it will fetch, then the full plan, and changes
      nothing
- [ ] the plan shows `containers: podman (rootless)`, `user: dsh`, `data: /srv/dsh/data/home`,
      the updater on `127.0.0.1` and `resources: 30%`
- [ ] the second asks the questions, shows the plan again and asks
      `Proceed? [Y/n]`
- [ ] it installs Node 22 (and says so), then `dsh` and `pnpm`; a missing Podman
      daemon is not an error for this run
- [ ] the installer ends with `==> installed: 0.2.1-rc.5-0.14.7`
- [ ] the self-check that follows reports `clean`: `service`, `web` and
      `data-owner` all ok
- [ ] `sudo ./setup.sh doctor` (no `--fix`) exits 0 and names the deployed
      `OPENCODE_GO_API_KEY` without printing it
- [ ] `./setup.sh doctor --fix` is idempotent: a second run changes nothing
- [ ] a repair run (`sudo ./setup.sh`, Enter at every prompt) does not ask for
      the provider key again and restarts the service once
- [ ] re-running `./setup.sh` with the same answers keeps
      `OPENCODE_GO_API_KEY` byte-for-byte (`grep ^OPENCODE_GO_API_KEY= .env`
      before and after) and leaves exactly one such line
- [ ] the summary prints `web: http://<ip>:<port>/?token=…` (read back from the
      runtime log), and `bot: configured` when a token was given
- [ ] it warns about web UI exposure when binding a LAN address
- [ ] re-running `./setup.sh` keeps the deployed git author as the prompt
      default (`git -C . config --file data/home/.gitconfig user.name` before
      and after)
- [ ] `systemctl status dsh.service` is `active (running)`
- [ ] `systemctl status dsh-updater.service` is `active (running)`
- [ ] `journalctl -u dsh.service -n 30` shows the runtime listening and the
      connector connected

## 2. First contact in Telegram

- [ ] send `/start` to the new bot: it answers with the help index
- [ ] `/workspace new uat` prints a `?startgroup=` link
- [ ] tap it, add the bot to a new group with Topics enabled: the group gets a
      dashboard
- [ ] `/new` in the group creates a topic; a message in it gets a streamed answer
- [ ] `/system status` shows: version `0.2.1-rc.5-0.14.7`, the admin line,
      `web: 127.0.0.1:<port> answered …`, `key: set`,
      `registry: 1 workspace(s) in the runtime · 1 bound to Telegram`,
      `data: … this runtime`, `last agent error: none`

## 3. The two surfaces, both directions

- [ ] send `/web` in the bot chat: a signed link, and the text says it is a
      credential
- [ ] open it in a browser on the LAN: the same topics are there
- [ ] send a prompt from the browser, in the topic of a session: **the echo
      (`you (web) · …`) and then the answer appear in Telegram, in that
      order, as two messages**
- [ ] send a prompt in Telegram: it appears in the browser and the answer
      streams in both
- [ ] with the browser open on a session, send a prompt from Telegram: the bot
      answers "this session is open in a web UI tab…" with a **Take over**
      button, and says the message is queued
- [ ] tap **Take over**: the runtime restarts, the queued message is delivered,
      and the session answers again in Telegram

## 4. A trial that commits

- [ ] `/system restart` → the card has **Commit** and **Roll back**, and a
      deadline
- [ ] `/system confirm` → the card closes; `/system status` shows no open trial
- [ ] the bot answered a message after the restart (nothing was lost)

## 5. A trial that rolls back by itself

- [ ] `/system restart` → **do not confirm**
- [ ] at the deadline the chat says `Rolled back to the last committed state: no
      confirmation within N minutes.`
- [ ] `/system status` shows no trial and `last event: rollback`

## 6. An update, and a cancel

- [ ] `/system update setup` → drains, then either finishes (setup update
      finished`) or reports why not. When this is the newest compatible tag,
      `no compatible tag after …` is the correct answer
- [ ] start `/system update setup` again and press **Cancel** during the drain:
      the card closes and normal messages work immediately after
- [ ] `/system cancel` in the chat does the same thing as the button

## 7. Component control (only if you installed the design stack)

- [ ] `/components` lists the components with their state
- [ ] change the Penpot port: the card reports done, the stack answers on the new
      port, and `/system status` still shows the runtime healthy
- [ ] disable it: the stack stops, the runtime keeps working

## 8. The restart the user reported

- [ ] create a workspace + session in the web UI, make no successful call, then
      `sudo systemctl restart dsh.service`
- [ ] the web UI still lists that workspace and its session
- [ ] `/system status` reports the same workspace count as the web UI
- [ ] a prompt in the Telegram topic works (no "held by another client")
- [ ] after the restart, `journalctl -u dsh.service -n 50` has no
      `already owned by an active write handle`

## 9. Plugin updates

- [ ] `/system update connector` → either reports `the connector is current
      (<version>); v<version> is the newest version`, or updates and returns in a
      trial. In both cases `/system status` still reports the runtime and the
      adapter, and the connector version is **not** the setup `VERSION`
- [ ] `/system update connector to <older version>` → refused as a rollback, with
      the current version named
- [ ] with the design stack enabled: `/system update penpot` → either current
      or updates through the plugin manager, in a trial; `penpot_status` still
      answers after the change
- [ ] `/system update plugin dsh-penpot-plugin` → the same result as
      `/system update penpot`
- [ ] `/plugins` lists both bundles; `/plugins info dsh-penpot-plugin` shows the
      version and source the update left in place
- [ ] `cat plugins.json` and `cat VERSION`: the plugin specs are exact
      `name@version` npm specs, the fallbacks point at the same version, and
      neither is derived from the setup tag

## 10. Uninstall

From the deployment checkout:

```sh
cd /srv/dsh
sudo ./setup.sh uninstall --check     # what it will stop and what it keeps
sudo ./setup.sh uninstall             # asks for confirmation
```

- [ ] `systemctl status dsh.service` says it does not exist
- [ ] `/usr/local/bin/dsh-*` launchers are gone
- [ ] `data/`, `.env` and `backups/` are still there
- [ ] the last lines say which user and directory remain, and how to remove them
- [ ] `sudo ./setup.sh uninstall --purge` removes `data/`, `.env` and
      `backups/` too

---

## What to send back

For each failed checkbox: the step, what you expected, what happened, and:

```sh
./setup.sh status
journalctl -u dsh.service -n 100
```

Do not paste `.env`. `/system status` and the logs never include the bot token or
the provider key.
