# Security

The deployment runs an agent with the service user's access on this host. This
page is what that means, what protects it, and what does not.

## Reporting

Open a private security advisory on GitHub, or email the maintainer at the
address in `package.json`. Please do not file a public issue for a working
exploit. Expect an answer within a few days.

## Threat model

- `dsh.service` runs as the unprivileged service user `dsh` and can read what
  that user can read: `/etc`, other projects under `/srv`, the host network. The
  systemd unit narrows writes to `<dir>/data` and blocks privilege escalation
  (`NoNewPrivileges`), but it is not a filesystem sandbox.
- `dsh-updater.service` runs as root because restarting `dsh.service` requires
  it. It listens on `127.0.0.1:8787` only, with the bearer token from `.env`.
- The agent and the connector share the `dsh` uid, so the agent's shell can read
  everything the connector can, including `DSH_TELEGRAM_BOT_TOKEN` and
  `DSH_UPDATER_TOKEN` in `.env` (mode `0640 root:dsh`).
- Telegram sees all message content; the bot token lets whoever holds it poll as
  the bot until revoked.

## What protects it

- **Allowlist and one admin.** `ALLOWED_USER_IDS` decides who may talk to the
  bot; `DSH_ADMIN_USER_ID` decides who may restart, update, roll back, install
  plugins or create workspaces. Empty allowlist refuses everyone.
- **A narrow updater.** It accepts a release tag and a mode, never a command. It
  is reachable only from the loopback interface and only with the token.
- **Root-owned control plane.** The checkout, the units and `install.sh` are
  root-owned; the runtime cannot rewrite the code that starts it. The supervisor
  (the recovery path) does not load plugins.
- **Trials.** A plugin change or restart opens a rollback window; a broken
  runtime is restored by the supervisor, not left in place.
- **Secrets on disk.** `.env` is `0640 root:dsh`; `secrets/git` is `0700` with
  `0600` files; `.credentials.yaml` is `0600`. Tokens are never in the profile
  patch or in git.
- **One runtime per data directory.** A kernel lock stops two runtimes from
  corrupting the session store or fighting over the bot token.

## What it does not protect

- A compromised bot token lets an attacker poll as the bot until the token is
  revoked with BotFather (`/revoke`).
- The agent can read host files the service user can read. If the host holds
  other tenants' secrets, use a VM.
- The updater token is root-equivalent for updates; the agent can read it. A
  prompt-injected agent can trigger a release update (a fixed action), not
  arbitrary root commands.
- Anyone who is an admin of a workspace group can close topics (archiving
  sessions) and rename the group (renaming the workspace).
- The web UI is plain HTTP unless a proxy terminates TLS; the token and cookie
  cross that network in clear text.

## Hardening checklist

- Bind `127.0.0.1` and use an SSH tunnel unless the LAN is trusted; never
  `0.0.0.0`.
- Keep `.env` at `0640 root:dsh` and `secrets/` at `0700`.
- List only your own Telegram ids in `ALLOWED_USER_IDS`, and set
  `DSH_ADMIN_USER_ID`.
- Keep `--containers podman` (rootless). Do not add `dsh` to the `docker`
  group; the rootful Penpot stack belongs to the updater.
- Set a resource share (`DSH_RESOURCE_PERCENT`) so a runaway command cannot take
  the host down.
- Revoke and replace a token if it ever appears in logs or a repository.
- Back up `data/` and `secrets/` separately (encrypted); `backups/self-*.tgz`
  holds git tokens too.

## Supported versions

The `main` branch is the only supported line while the project is pre-1.0.
Security fixes ship in the next release tag; tags are immutable.
