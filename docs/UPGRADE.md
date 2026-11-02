# Upgrading, and rolling back

An upgrade moves the setup checkout to a newer tag, rebuilds the runtime image,
and starts it under a trial. Nothing is committed until the new runtime is
healthy **and** someone confirms it; otherwise the supervisor restores the
previous checkout, image and profile by itself.

Read this before the first upgrade you actually need, and run the drill once
while nothing is at stake.

## What an upgrade touches

| Path | What happens |
|---|---|
| the checkout (`git` tag) | `git checkout --detach <target>`; the previous tag stays reachable |
| the image | rebuilt as `dsh-backend:<target>`; the running image is kept as `dsh-backend:self-previous` |
| `data/home`, `data/supervisor` | snapshotted to `backups/self-<stamp>.tgz` (mode `0600`, it holds git tokens) |
| `.env` | `DSH_SETUP_VERSION` is rewritten so the entrypoint installs the matching connector tag |
| `data/workspace` | untouched |

`VERSION`, the image tag, the Dockerfile's `DSH_SETUP_VERSION` and the connector
tag are one release: they only ever move together, which is why the setup tag
and the connector tag are always identical.

## Which upgrades are allowed

```
<dsh-version>-<major>.<minor>.<patch>      v0.2.1-rc.2-0.6.0
```

- **Compatible** (the default): same DSH part, same product major. Any newer
  tag is fine, and jumps are fine (`0.6.0 → 0.9.1`).
- **Crossing** a DSH line or a product major needs the explicit flag
  `/system update all --i-know-versions-are-incompatible` (or
  `./update.sh --self --i-know-versions-are-incompatible`). Neither path crosses
  on its own, and the updater refuses targets that are not newer.

## Upgrading from Telegram

```
/system update all
```

What happens, in order:

1. The bot reports the drain and waits for every agent to go idle (a web UI turn
   counts too; `/system status` shows who is blocked).
2. The updater runs `update.sh --self-to <latest compatible tag>` on the host.
3. The runtime stops, the image builds, the new one starts under a trial.
4. The updater reports the result in the chat: `✅ setup update finished: vA → vB`.

If it fails, the report says so and the previous setup is running again. If the
drain never finishes, `/system cancel` cancels it (it also cancels a running
updater job).

## Upgrading from the host

```sh
./update.sh --self-check    # what a compatible upgrade would do; changes nothing
./update.sh --self          # do it, with the first prompt asking to confirm
./update.sh --self-to v0.2.1-rc.2-0.6.0   # an exact target (what the updater uses)
```

Use this for a broken bot, a first install of the updater, or a deliberate
manual upgrade. It is the same code path the updater runs.

## The trial, and confirming it

Every upgrade opens a trial: the supervisor watches the new runtime, and the
bot posts a card with **Commit** and **Roll back** plus a deadline
(`DSH_TRIAL_SECONDS`, 5 minutes by default).

- `/system confirm` (or **Commit**) keeps the new release and makes it the
  rollback point.
- `/system rollback` (or **Roll back**) restores the previous checkout, image and
  profile.
- Doing nothing until the deadline rolls back automatically.
- A new runtime that never comes up rolls back after `DSH_BOOT_GRACE_SECONDS`
  (120 s), or immediately if it exits.

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

A rollback that works here is the same one an upgrade uses. If the card never
arrives, the supervisor or its token is misconfigured — fix that before you need
a rollback for real (`/system status` reports both).

`./update.sh --self-to <current tag>` is **not** a no-op drill: an exact-or-older
target is refused on purpose, so the drill has to be the trial above.

## Upgrading from an older install (0.4.x and before)

Nothing has to be done by hand:

- missing `.env` keys are filled from defaults on the next `./install.sh` (the
  installer also says when an exported variable overrides a deployed value);
- if `DSH_ADMIN_USER_ID` is absent, the owner of the bot chat is the admin, so
  an upgrade cannot lock you out; new installs always set it;
- `bindings.json` from an older connector is read as-is. If it cannot be read,
  it is kept aside (`bindings.json.corrupt-<ts>`) and the bot says so once in the
  chat: run `/sync` in each group to rebuild the topic bindings.

## When something goes wrong

| Symptom | What it means | What to do |
|---|---|---|
| Card says `⚠️ the supervisor is busy` | another operation held it | wait, then `/system rollback` again |
| Card says `no trial is running` | it expired or was already committed | `/system status` shows the last event |
| `Rollback failed (…)` | the profile could not be restored | the runtime restarted on the current files; `docker compose logs dsh`, and `backups/self-*.tgz` is the manual restore input |
| Bot does not come back after an update | the trial rolled back but the runtime is unhealthy | `docker compose ps`, `docker compose logs dsh`, then `./update.sh --self-to <previous tag>` |
| Updater unreachable | token mismatch or the sidecar is down | `docker compose ps updater`, `docker compose logs updater` |
| Half-applied checkout | stopped between build and start | `git -C <dir> checkout --detach v$(docker inspect --format '{{.Config.Image}}' dsh | cut -d: -f2)` then `docker compose up -d dsh` |

Native mode has no image: the same steps apply, but the previous release is a
tag, not `dsh-backend:self-previous`, and `journalctl -u dsh.service -f` replaces
the container log.

## Checklist

- [ ] `/system status` shows the updater `ready` and the supervisor `present`
- [ ] the drill above rolled back on its own
- [ ] `backups/self-*.tgz` is `0600` and recent
- [ ] after the upgrade: `/system status` shows `web: … answered 200`, `key: set`,
      and the new version in `/about`
- [ ] after committing: `/system status` shows no open trial
