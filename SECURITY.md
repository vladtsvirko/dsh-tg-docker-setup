# Security

This container runs an agent with host-level permissions *inside* the container
boundary. Treat `/data` and the bot token as the sensitive material.

## Reporting

Open a private GitHub security advisory. Do not file a public issue for a working
exploit.

## Two modes

`install.sh --mode docker` (the default) keeps the boundary described below.
`install.sh --mode native` runs the same runtime under systemd as the service
user, without Docker: the agent can then read what that user can read, and the
updater service (root, loopback only) is the only privileged component. Native
mode's tiers, hardening and limits are in [docs/HOST.md](docs/HOST.md). Never
run the runtime itself as root.

## The deployment's own rules

- `DSH_BIND_IP` keeps the web UI on one host interface. Never publish it on
  `0.0.0.0`.
- The runtime container is the sandbox: `read_only` rootfs, `cap_drop: ALL`,
  `no-new-privileges`, no Docker socket. Do not add the socket "temporarily".
- The separate `updater` sidecar is the only component with the Docker socket.
  That socket is host-root-equivalent. It publishes no port; its API answers only
  on the internal `ops` network and needs `DSH_UPDATER_TOKEN` — treat that token
  as a root credential, and empty it to disable apply. It also joins the compose
  `default` network (to probe the runtime's web port) and the `design` network
  (to probe the Penpot frontend), so it can reach those two services; it cannot
  start anything by that route, only read their HTTP ports.
- `.env` holds the bot token and model key. Keep it `chmod 600`, never commit it
  (the `data/` volume and `.env` are ignored).
- `/data` is the only persistent path. Back it up; anyone with it has the session
  history and the profile.
- `ALLOWED_USER_IDS` is the gate for using the bot; `DSH_ADMIN_USER_ID` is the
  separate gate for changing the deployment (restart, update, rollback, plugins,
  workspaces). Empty allowlist refuses everyone. The connector's inline buttons
  currently check the allowlist only — see its `SECURITY.md`.
- The supervisor's control socket is loopback-only and bearer-authenticated; its
  token is generated per container start.
- The one-shot `init` service runs as root only to chown `./data` to `DSH_UID`.
  It has no network, a read-only rootfs, and only `CHOWN` and `DAC_OVERRIDE`;
  the runtime itself never runs as root.

## If a credential leaks

The bot token, the provider key, the updater token and the web UI's sign-in
token are all passwords. What to do, in the order that limits damage:

**Bot token** (it can read every message the bot sees, and send as it):

```sh
# 1. revoke it: @BotFather → /revoke → pick the bot (the old token dies at once)
# 2. put the new one in .env
sed -i 's|^DSH_TELEGRAM_BOT_TOKEN=.*|DSH_TELEGRAM_BOT_TOKEN=<new>|' .env
# 3. recreate the runtime so the entrypoint rewrites the connector config
docker compose up -d dsh
# 4. confirm the old poller is gone: no 409 "terminated by other getUpdates"
docker compose logs --since 2m dsh | grep -i 'conflict\|terminated'
```

**Web UI sign-in token** (it grants browser access to the agent):

```sh
docker compose restart dsh   # a restart mints a new launch token
```
Every link handed out before the restart stops working. The token lives in the
container log (`dsh web: …`), which is why the log is a credential: use
`/web` in the bot chat instead of grepping it, and do not paste it in a group.

**Provider key** (billing and rate limits):

Revoke it in the provider console, put the new value in `.env`, then
`docker compose up -d dsh`. `/system status` reports `key: set|missing`.

**Updater token** (equivalent to root: it restarts the stack with a Docker
socket):

```sh
# rotate it in .env, then recreate BOTH services so the sidecar and runtime agree
sed -i 's|^DSH_UPDATER_TOKEN=.*|DSH_UPDATER_TOKEN=<new>|' .env
docker compose up -d updater dsh
```
Empty (`DSH_UPDATER_TOKEN=`) disables apply entirely: `/system update all` then
tells the user to update from the host.

**Git token** (repository access only): rotate the profile in
`data/home/.dsh/git`, and check the rollback snapshots — `backups/self-*.tgz`
contains them and is `0600` for that reason.

After any rotation, run `/system status` in the bot chat: it reports the web
port, the key and the last agent error, which is the fastest way to see that the
new credential is the one in use.

## What is not protected

- A leaked bot token lets the holder poll and act as the bot until revoked with
  BotFather (`/revoke`).
- Group admins can rename topics/groups, close sessions and delete topics.
- The agent runs with `danger-full-access` inside the container; anything mounted
  into it is reachable by the agent.
