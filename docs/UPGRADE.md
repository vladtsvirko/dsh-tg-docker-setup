# Upgrading, and rolling back

An upgrade moves the setup checkout to a newer tag and installs the matching
DSH. A health gate decides the outcome: a healthy runtime keeps the new tag, and
a failure restores the previous tag and the data snapshot automatically.

Read this before the first upgrade you actually need, and run the drill once
while nothing is at stake. To learn whether there is anything to upgrade to, and
what it would cost, see [`UPSTREAM-WATCH.md`](UPSTREAM-WATCH.md) and the version
rules in [`VERSIONS.md`](VERSIONS.md).

## What an upgrade touches

| Path | What happens |
|---|---|
| the checkout (`git` tag) | `git checkout --detach <target>`; the previous tag stays reachable |
| the installed DSH | `npm install -g @deepseek-ai/dsh@<DSH part>` when the DSH part changes |
| `data/home`, `data/supervisor` | snapshotted to `backups/self-<stamp>.tgz` |
| `.env` | `DSH_SETUP_VERSION` is rewritten so the entrypoint knows which setup it is running |
| `data/workspace` | untouched |

The setup is one release with DSH; the connector and Penpot plugin are versioned
independently and need no matching setup tag. The DSH part is the prefix of
`VERSION`; there is no separate DSH pin to edit. `plugins.json` pins the
exact npm plugin specs, their GitHub fallbacks and the minimum floor a boot enforces.

## Which upgrades are allowed

```
<dsh-version>-<major>.<minor>.<patch>      v0.2.1-rc.5-0.14.0
```

- **Compatible** (the default): same DSH part, same product major. Any newer
  tag is fine, and jumps are fine (`0.6.0 → 0.9.1`).
- **Crossing** a DSH line or a product major needs the explicit flag
  `/system update setup --i-know-versions-are-incompatible` (or
  `./setup.sh update --i-know-versions-are-incompatible`). Neither path crosses
  on its own, and the updater refuses targets that are not newer.

## Upgrading from Telegram

```
/system update setup
```

What happens, in order:

1. The bot reports the drain and waits for every agent to go idle (a web UI turn
   counts too; `/system status` shows who is blocked).
2. The updater runs `setup.sh update --to <latest compatible tag>` on the host.
3. The target tag is checked out and the matching DSH installed while the old
   runtime runs; `dsh.service` is restarted, and the new runtime must pass the
   health gate (the unit active **and** the web port answering).
4. The updater reports the result in the chat: `setup update finished: vA → vB`.

If it fails, the report says so and the previous tag and the data snapshot are
back in place. If the drain never finishes, `/system cancel` cancels it (it also
cancels a running updater job).

## Upgrading from the host

```sh
sudo ./setup.sh update --check    # what a compatible upgrade would do; changes nothing
sudo ./setup.sh update          # do it, with the first prompt asking to confirm
sudo ./setup.sh update --to v0.2.1-rc.5-0.14.0   # an exact target (what the updater uses)
```

Use this for a broken bot, a first install of the updater, or a deliberate
manual upgrade. It is the same code path the updater runs.

## Trials and health gates are not the same thing

Two mechanisms look alike and are not:

**A profile change** — `/system restart`, `/system update connector`, a plugin
install — opens a supervisor **trial**. The bot posts a card with **Commit** and
**Roll back** and a deadline (`DSH_TRIAL_SECONDS`, 5 minutes by default).

- `/system confirm` (or **Commit**) keeps the change and makes it the rollback
  point.
- `/system rollback` (or **Roll back**) restores the previous profile state and
  restarts. It does not move the setup tag.
- Doing nothing until the deadline rolls back automatically.
- A runtime that never comes up rolls back after `DSH_BOOT_GRACE_SECONDS`
  (120 s), or immediately if it exits.

**A setup upgrade** — `/system update setup` or `./setup.sh update` — opens no
trial and posts no Commit/Roll back card. It has a **health gate** instead: the
restarted service must be active **and** answer on the web port. If either
fails, `setup.sh update` restores the snapshot, checks the previous tag out, rewrites
the version and restarts by itself, then reports the rollback in the chat.
There is nothing to confirm and no deadline: success is final, failure is
automatic.

## The drill: prove the rollback works

Run this once, on a quiet deployment:

```sh
# 1. note where you are
/system status

# 2. open a trial without changing anything
/system restart

# 3. do not confirm. Watch the card: it carries a deadline.
#    At the deadline the supervisor restores the committed state and announces
#    "Rolled back to the last committed state: no confirmation within N minutes."
```

That proves the supervisor, the bot and the trial card. It does **not** exercise
the setup rollback, which is the updater's health gate, not a trial: to drill
that one, break a disposable deployment on purpose (a target whose unit cannot
start, or a web bind that does not answer) and watch `setup.sh update` restore
the previous tag and snapshot and report `rolled back`; the apply path it
exercises is [`SELF-UPDATE.md`](SELF-UPDATE.md). If the card never arrives, the
supervisor or its token is misconfigured — fix that before you need a rollback
for real (`/system status` reports both).

`./setup.sh update --to <current tag>` is **not** a no-op drill: an exact-or-older
target is refused on purpose, so the drill has to be the trial above.

## Upgrading from an older install (0.4.x and before)

Nothing has to be done by hand:

- missing `.env` keys are filled from defaults on the next `./setup.sh` (the
  installer also says when an exported variable overrides a deployed value);
- if `DSH_ADMIN_USER_ID` is absent, the owner of the bot chat is the admin, so
  an upgrade cannot lock you out; new installs always set it;
- `bindings.json` from an older connector is read as-is. If it cannot be read,
  it is kept aside (`bindings.json.corrupt-<ts>`) and the bot says so once in the
  chat: run `/sync` in each group to rebuild the topic bindings.

## When something goes wrong

| Symptom | What it means | What to do |
|---|---|---|
| Card says `the supervisor is busy` | another operation held it | wait, then `/system rollback` again |
| Card says `no trial is running` | it expired or was already committed | `/system status` shows the last event |
| `Rollback failed (…)` | the profile could not be restored | the runtime restarted on the current files; `journalctl -u dsh.service`, and `backups/self-*.tgz` is the manual restore input |
| Bot does not come back after an update | the automatic rollback ran, or the health gate never passed, and the runtime is unhealthy | `systemctl status dsh.service`, `journalctl -u dsh.service -n 100`; then use [Manual recovery](#manual-recovery) below |
| Updater unreachable | token mismatch or the service is down | `systemctl status dsh-updater.service`, `journalctl -u dsh-updater.service` |
| Half-applied checkout | stopped between checkout and restart | [Manual recovery](#manual-recovery) below |

`--to` cannot go backwards: it refuses older tags on purpose, so a manual
recovery is a host operation.

### Manual recovery

Use the tag you came from and the snapshot the failed update made:

```sh
cd /srv/dsh
sudo systemctl stop dsh.service
sudo git checkout --detach v<previous>
sudo rm -rf data/home data/supervisor
sudo tar xzf backups/self-<stamp>.tgz -C data
sudo chown -R dsh:dsh data/home data/supervisor
# set DSH_SETUP_VERSION=<previous version> in /srv/dsh/.env
# if the upgrade crossed a DSH line, also:
# sudo npm install -g @deepseek-ai/dsh@<previous DSH part>
sudo systemctl start dsh.service
```

The `rm -rf` mirrors what the automatic rollback does: the snapshot replaces
`data/home` and `data/supervisor`, so anything written there after the snapshot
is gone. Then check `journalctl -u dsh.service -n 100` and `/system status`.

## Checklist

- [ ] `/system status` shows the updater `ready` and the supervisor `present`
- [ ] the drill above rolled back on its own
- [ ] `backups/self-*.tgz` is recent
- [ ] after the upgrade: `/system status` shows `web: … answered 200`, `key: set`,
      and the new version in `/system status`
- [ ] after committing: `/system status` shows no open trial
