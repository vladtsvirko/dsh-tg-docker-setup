# Operating limits and restrictions

This page is the honest boundary of the deployment. It exists so that "works
from Telegram" is not confused with "every possible failure is remotely
recoverable".

## The control path

```text
Telegram → connector → dsh runtime / supervisor
                    └→ dsh-updater.service → systemd → host
```

Telegram is the **only** ordinary control path. There is no host shell exposed to
the bot. The runtime is an unprivileged systemd service: it cannot restart its
own unit, write outside its data directory, or modify the root-owned checkout.
The updater service is the only privileged unit, and it exists to restart the
runtime.

### Covered without a host shell

- prompts, sessions, topics, `/sync`, model and timezone changes;
- `/system restart`, trials, `/system confirm`, `/system rollback` (profile);
- `/system update connector` (reinstall the pinned connector);
- `/system update all` (drain, setup update, automatic rollback);
- plugin install/enable/disable/remove through the approval flow;
- `/about`, `/system status`, `/status` diagnostics;
- Telegram reports for update success, failure and rollback.

### Still requires host access

These cannot be done through the bot, by design or by physics:

- the deployment checkout: first install, editing `.env`, changing the units;
- running `update.sh` or `install.sh` from a workspace **inside the runtime** —
  the service user cannot write the root-owned checkout or restart the unit.
  Node/npm tests and static checks do work there;
- changing the updater service's unit or the host packages it uses (Node, git,
  curl);
- fixing systemd, a full disk, ownership outside `data/`, or a host firewall;
- recovering a wedged updater, a half-applied update, or a runtime that cannot
  start at all;
- reading `journalctl -u dsh.service` when the connector itself is down or cannot
  reach Telegram;
- adding publisher bots to groups (a human must add them; the Bot API cannot);
- creating a group or enabling Topics (Telegram only allows a human to do this);
- changing `DSH_BIND_IP`, the port, the resource share, the tier, or the unit
  files;
- retrieving the web token if the browser cookie is gone and the runtime logs
  are unreachable;
- rolling the setup tag back manually. `/system rollback` restores the profile,
  not the checkout or the tag.

If SSH is removed, those cases have no remote recovery path. Keep a break-glass
option (physical console, out-of-band management, or a documented SSH key) if
the deployment matters. The update gate reduces the chance of a bad release, but
it cannot repair a dead bot, a dead updater, or a dead systemd.

## Update restrictions

- `/system update all` drains **all** agents, including sessions owned by a web
  UI tab. A web turn can still start in the instant before the updater restarts
  the service; that race is best-effort and accepted.
- The updater stops a job that runs longer than `DSH_UPDATE_TIMEOUT_SECONDS`
  (default 30 minutes) and `/system cancel` cancels a running one: the job gets
  `SIGTERM`, then `SIGKILL` after ten seconds. A cancelled or timed-out update is
  reported in the chat; the runtime may need `/system restart` afterwards.
- The Cancel button before acceptance still only clears the pending request.
- New prompts are blocked while the update is pending. Messages sent while dsh is
  down are answered once after boot with "update finished — send it again" and
  are **not** executed.
- Compatible means same DSH part and same product major. Crossing either needs
  `--i-know-versions-are-incompatible`; `/system` never crosses without it.
- The updater refuses older targets. It only moves forward.
- The updater updates the **dsh** service; it does not rewrite its own unit. Its
  code is the checkout it runs, so a unit change needs
  `sudo ./install.sh --yes`, not an update.
- A crash of the updater during apply is not automatically resumed. The persisted
  `data/update/result.json`, the checkout and the snapshot are the recovery
  inputs.
- If the health gate fails, the updater restores the snapshot and the previous
  tag, then reports the last log lines. Verification includes the **web port**,
  not only the unit being active.

## Rollback and data

- One `backups/self-*.tgz` (home + supervisor) is kept. There is no history.
- `data/workspace` is never snapshotted or restored. Files created there after
  the snapshot survive a profile rollback, but a failed deployment's own changes
  to the workspace are not undone.
- A rollback restores `data/home` and `data/supervisor` to the snapshot. Data
  written after that snapshot is lost if a rollback restores it.
- A profile trial (supervisor) covers `data/home/profiles/web` only. Sessions,
  bindings, the workspace and the setup checkout are outside it.
- A direct edit under `data/home` while the service is stopped is outside every
  trial.
- `/system rollback` does not move the setup tag. A failed health gate rolls the
  tag back automatically; a manual tag rollback is a host operation (checkout
  plus snapshot).

## Security boundaries

- The runtime is an unprivileged systemd service running as `dsh`. The unit
  narrows writes, but it is not a filesystem sandbox: the agent can read what
  that user can read. It runs with `DSH_PERMISSION_MODE=danger-full-access`,
  `ProtectSystem=strict`, `ProtectHome=yes`, `NoNewPrivileges`, `PrivateTmp`,
  and writes only under `<dir>/data`. Everything under `/srv/dsh/data` is
  reachable by the agent.
- The **updater** is the exception: it runs as root because restarting
  `dsh.service` requires it. It binds `127.0.0.1:8787` only and is reachable
  only with `DSH_UPDATER_TOKEN`. Treat that token as a root credential.
- The agent and the connector share the `dsh` uid, so the agent can read
  `.env`, including `DSH_UPDATER_TOKEN`. A prompt-injected agent can trigger a
  release update (a fixed action), not arbitrary root commands.
- `DSH_UPDATER_TOKEN` empty disables apply; `/system update all` degrades to
  diagnostics/host instructions.
- `DSH_BIND_IP` publishes the web UI on one host interface. Never use `0.0.0.0`;
  the UI drives a shell. `127.0.0.1` means host-only, normally via an SSH tunnel,
  and requires `DSH_PUBLIC_URL=http://127.0.0.1:<port>/` as well — without it the
  UI advertises the bind address and reconnects forever.
- `ALLOWED_USER_IDS` is the only Telegram authorization gate. Empty refuses
  everyone, including the owner.
- The web URL token and its signed cookie are credentials. Do not paste them into
  issues or logs. The update log tail redacts the Telegram token, not the web
  token.
- Publisher bot tokens only send; the main bot polls and owns buttons. Publishers
  must be added to every group by a human.
- Plugin code and install scripts run with the runtime's permissions. `/plugin
  add` inspects, `/plugin confirm` is explicit, and `/plugin approve` allows only
  the named blocked build scripts.

## Telegram and web constraints

- One bot cannot create a group or enable Topics. A human must do both.
- Topic operations require the bot to be an admin with **Manage topics**. The
  connector retries each operation; it no longer latches topic management off
  after one failure.
- The Bot API cannot list topics or read history, and a bot does not receive its
  own messages. `/sync` works from DSH's session registry, not from Telegram
  history.
- About 20 messages/minute per bot per group, about one edit/second per chat.
  The outbox is per group; publisher bots multiply the ceiling.
- One poller per bot token. Two connectors sharing a token fight over updates.
- A session has one live agent. If a web UI tab owns it, a Telegram prompt is
  refused until the tab closes.
- Topic names are limited to 128 characters; messages to 4096; there are no
  threads inside topics.
- The web UI is plain HTTP on the LAN unless a proxy provides TLS. The token and
  cookie cross that LAN in clear text.
- TLS is a proxy's job: the entrypoint does not pass `--tls-cert`/`--tls-key`,
  and the setup does not terminate TLS. Terminate TLS in front, set
  `DSH_PUBLIC_URL` to the **https** root, and keep one authority: the entrypoint
  derives the single trusted host from `DSH_PUBLIC_URL`, so a second proxy
  hostname answers 403 until it is the configured one.

## Version restrictions

See [`VERSIONS.md`](VERSIONS.md). In short:

- both repositories share one tag;
- the setup boot pin forces the connector tag derived from `VERSION`;
- a setup release needs a connector tag, and a deployed connector change needs a
  setup release;
- tags are immutable;
- the updater only moves forward within the same DSH line and product major
  unless the explicit incompatibility flag is given.
