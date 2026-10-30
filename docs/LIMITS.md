# Operating limits and restrictions

This page is the honest boundary of the deployment. It exists so that "works
from Telegram" is not confused with "every possible failure is remotely
recoverable".

## The control path

```text
Telegram → connector → dsh runtime / supervisor
                    └→ updater sidecar → docker → host
```

Telegram is the **only** ordinary control path. There is no systemd unit, no
host shell exposed to the bot, and no Docker socket in the runtime container.

### Covered without a host shell

- prompts, sessions, topics, `/sync`, model and timezone changes;
- `/system restart`, trials, `/system confirm`, `/system rollback` (profile);
- `/system update connector` (reinstall the pinned connector);
- `/system update all` (drain, setup/image update, automatic rollback);
- plugin install/enable/disable/remove through the approval flow;
- `/about`, `/system status`, `/status` diagnostics;
- Telegram reports for update success, failure and rollback.

### Still requires host access

These cannot be done through the bot, by design or by physics:

- the first install, cloning the setup, and editing `.env`;
- rebuilding or changing the **updater image** or its dependencies
  (`updater.Dockerfile`, Node, Docker CLI/compose, git, curl);
- fixing Docker, the daemon, disk-full, bind mounts, file ownership outside the
  container, or a host firewall;
- recovering a wedged updater, a half-applied update, or a dsh image that cannot
  start at all;
- reading `docker compose logs` when the connector itself is down or cannot
  reach Telegram;
- adding publisher bots to groups (a human must add them; the Bot API cannot);
- creating a group or enabling Topics (Telegram only allows a human to do this);
- changing `DSH_BIND_IP`, the port, UID/GID, memory/CPU limits, or the compose
  file;
- retrieving the web token if the browser cookie is gone and the runtime logs
  are unreachable;
- rolling the **image** back manually. `/system rollback` restores the profile,
  not the image.

If SSH is removed, those cases have no remote recovery path. Keep a break-glass
option (physical console, out-of-band management, or a documented SSH key) if
the deployment matters. The update gate reduces the chance of a bad image, but it
cannot repair a dead bot, a dead updater, or a dead Docker daemon.

## Update restrictions

- `/system update all` drains **all** agents, including sessions owned by a web
  UI tab. A web turn can still start in the instant before the updater stops the
  container; that race is best-effort and accepted.
- After the updater accepts the job there is **no timeout and no cancel**. A stuck
  session blocks the update until it finishes or is cancelled at the session
  level. The Cancel button exists only before acceptance.
- New prompts are blocked while the update is pending. Messages sent while dsh is
  down are answered once after boot with "update finished — send it again" and
  are **not** executed.
- Compatible means same DSH part and same product major. Crossing either needs
  `--i-know-versions-are-incompatible`; `/system` never crosses without it.
- The updater refuses older targets. It only moves forward.
- The updater updates the **dsh** service, not its own image. Its mounted
  `updater.mjs` reloads, but a change to `updater.Dockerfile` or its OS packages
  needs a host rebuild.
- A crash of the updater during apply is not automatically resumed. The persisted
  `data/update/result.json`, the checkout, the images and the container state are
  the recovery inputs.
- If the health gate fails, the updater restores the previous image and the
  snapshot, then reports the last log lines. Verification includes the
  **published** web port, not only the container healthcheck.

## Rollback and data

- One previous image is kept (`dsh-backend:self-previous`) and one
  `backups/self-*.tgz` (home + supervisor). There is no history.
- `data/workspace` is never snapshotted or restored. Files created there after
  the snapshot survive a profile rollback, but a failed deployment's own changes
  to the workspace are not undone.
- A rollback restores `data/home` and `data/supervisor` to the snapshot. Data
  written after that snapshot is lost if a rollback restores it.
- A profile trial (supervisor) covers `data/home/profiles/web` only. Sessions,
  bindings, the workspace and the setup checkout are outside it.
- A direct edit under `data/home` while the container is stopped is outside every
  trial.
- `/system rollback` does not move the image or the setup tag. Image rollback is
  automatic on a failed health gate; manual image rollback is a host operation.

## Security boundaries

- The runtime container is the sandbox. It runs with
  `DSH_PERMISSION_MODE=danger-full-access`, a read-only rootfs, `cap_drop: ALL`,
  `no-new-privileges`, and no Docker socket. Everything mounted under `/data` is
  reachable by the agent.
- The **updater** is the exception: it mounts the Docker socket and is therefore
  host-root-equivalent. It has no published port and is reachable only on the
  internal `ops` network with `DSH_UPDATER_TOKEN`. Treat that token as a root
  credential.
- `DSH_UPDATER_TOKEN` empty disables apply; `/system update all` degrades to
  diagnostics/host instructions.
- `DSH_BIND_IP` publishes the web UI on one host interface. Never use `0.0.0.0`;
  the UI drives a shell. `127.0.0.1` means host-only, normally via an SSH tunnel.
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

## Version restrictions

See [`VERSIONS.md`](VERSIONS.md). In short:

- both repositories share one tag;
- the setup boot pin forces the connector tag derived from `VERSION`;
- a setup release needs a connector tag, and a deployed connector change needs a
  setup release;
- tags are immutable;
- the updater only moves forward within the same DSH line and product major
  unless the explicit incompatibility flag is given.
