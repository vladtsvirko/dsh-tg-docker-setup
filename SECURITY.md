# Security

This container runs an agent with host-level permissions *inside* the container
boundary. Treat `/data` and the bot token as the sensitive material.

## Reporting

Open a private GitHub security advisory. Do not file a public issue for a working
exploit.

## The deployment's own rules

- `DSH_BIND_IP` keeps the web UI on one host interface. Never publish it on
  `0.0.0.0`.
- The container is the sandbox: `read_only` rootfs, `cap_drop: ALL`,
  `no-new-privileges`, no Docker socket. Do not add the socket "temporarily".
- `.env` holds the bot token and model key. Keep it `chmod 600`, never commit it
  (the `data/` volume and `.env` are ignored).
- `/data` is the only persistent path. Back it up; anyone with it has the session
  history and the profile.
- `ALLOWED_USER_IDS` is the only gate on Telegram. Empty refuses everyone.
- The supervisor's control socket is loopback-only and bearer-authenticated; its
  token is generated per container start.

## What is not protected

- A leaked bot token lets the holder poll and act as the bot until revoked with
  BotFather (`/revoke`).
- Group admins can rename topics/groups, close sessions and delete topics.
- The agent runs with `danger-full-access` inside the container; anything mounted
  into it is reachable by the agent.
