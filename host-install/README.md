# DSH backend on a home server

> **Chosen deployment: Docker.** See the [repository README](../README.md) —
> one container serves the web UI *and* the Telegram bot, with the container as
> the security boundary. This file documents the alternative host install with a
> dedicated Unix user, kept for reference only.

Goal: one DeepSeek Harness runtime on the Ubuntu 22.04 box, reachable from two clients.

```
                    ┌──────────────────── Ubuntu 22.04 ────────────────────┐
 Mac browser ──────►│  dsh --profile web  --host <lan-ip> --port 4310      │
 (LAN, http)        │    ├── web UI + /api (browser trust fence + token)   │
                    │    ├── agents / tools / sessions  (one store)        │
 Telegram ─────────►│    └── dsh-telegram plugin (long poll, allowlist)    │
 (api.telegram.org) │        /srv/dsh/home   /srv/dsh/workspace           │
                    └──────────────────────────────────────────────────────┘
```

Both clients drive the *same* runtime and the same agent definitions. Sessions are separate
(the web UI has its own conversations, each Telegram chat gets one), but tools, profile,
model route and workspace are shared.

## What's in this directory

| File | Purpose |
|---|---|
| `setup-dsh-server.sh` | Idempotent bootstrap: Node, dsh, profile, Telegram plugin, `.env`, systemd unit |
| `README.md` | This runbook |

## Model route

This script defaults to `deepseek-official` and needs no extra profile config for
it. For `opencode-go` (or any pi-ai provider) a provider row must also be added to
`$DSH_HOME/profiles/web/cordis.patch.yml`:

```yaml
- id: llm-pi-ai
  config:
    providers:
      opencode-go:
        apiKeyEnv: OPENCODE_GO_API_KEY
- id: agent-default-model
  config:
    provider: opencode-go
    model: deepseek-v4.1-flash
```

The Docker entrypoint does this automatically from `DSH_PROVIDER`; this host
variant expects you to add it by hand.

## Prerequisites

- Ubuntu 22.04 with sudo, and outbound HTTPS (NodeSource, npm registry, api.telegram.org)
- Node **≥ 22.19** — the script installs Node 24 from NodeSource if needed
- A provider API key (`DEEPSEEK_API_KEY`, or `OPENCODE_GO_API_KEY` if you use the opencode-go route)
- A Telegram bot token from [@BotFather](https://t.me/BotFather)
- Your Telegram **user id** (message [@userinfobot](https://t.me/userinfobot); the *number*, not the @handle)

## Quick start

Copy the script to the server, then:

```sh
chmod +x setup-dsh-server.sh
sudo -E ALLOWED_USER_IDS=123456789 TELEGRAM_BOT_TOKEN='123456:ABC...' ./setup-dsh-server.sh
```

Then drop the API key in and restart:

```sh
sudo nano /srv/dsh/home/.env       # fill DEEPSEEK_API_KEY=
sudo systemctl restart dsh
journalctl -u dsh -f
```

Open `http://<lan-ip>:4310/` on the Mac (the CLI prints a `?token=…` URL on first boot; the token
is what the browser uses, so use that link rather than the bare origin). Send `/start` to the bot.

Dry run first if you want to see every action:

```sh
sudo -E ./setup-dsh-server.sh --check
```

## What the script does

1. Installs `curl`, `git`, Node 24 (NodeSource), **pnpm** and `dsh` from npm.
   The npm install passes `--allow-scripts=` for `node-pty`, `koffi` and the
   subprocess spawn helper — npm 11 skips dependency install scripts by default,
   and without them the agent's bash tool fails at runtime.
2. Creates the `dsh` service user, `/srv/dsh/home` (`DSH_HOME`) and `/srv/dsh/workspace`.
3. Materialises the `web` profile and installs `github:ben7am1n/dsh-telegram` into it — handling
   the two gates described below.
4. Pins the adapter's config in the profile patch: `allowedUserIds`, `provider`, `model`, `cwd`.
5. Writes `/srv/dsh/home/.env` (mode 600) with the bot token; secrets only, nothing else.
6. Installs `dsh.service` (systemd, `Restart=on-failure`) and starts it.

Everything is re-runnable: an existing profile, `.env`, or pinned config is left alone and logged.

## Two gates you will hit installing the adapter

The adapter is a *dsh plugin* (it mounts into the plugin tree and drives `ctx.agents`), not a
standalone service. Installing it into a profile has two failure modes, both handled by the script:

1. **pnpm refuses to build a git dependency.**
   `ERR_PNPM_GIT_DEP_PREPARE_NOT_ALLOWED` → the exact `allowBuilds` key pnpm prints is appended to
   `<profile>/pnpm-workspace.yaml`, then the install is retried.
   The package builds itself with a `prepare` script that runs `pnpm install`, so **pnpm must be on
   PATH** — that's why the script installs it globally.

2. **Version gate.** The adapter declares peers on `@deepseek-ai/dsh-{agent,llm,session}@^0.1.0-rc.6`
   and is verified against `dsh 0.1.0-rc.6`, while npm currently ships `0.2.1-rc.x`. dsh refuses to
   mount it until you grant an explicit exemption:

   ```sh
   dsh plugin --profile web allow-version dsh-telegram@0.1.0 --dsh-version <installed> --accept-risk
   ```

   The script does this automatically (`ALLOW_INCOMPATIBLE=1`, the default) and warns loudly.
   **This is an unverified combination** — the wire/`ctx.agents` surface may have changed between
   RC lines. If the bot misbehaves (no replies, crashes on prompt), fall back to the version the
   adapter was actually tested against:

   ```sh
   sudo -E DSH_PKG=@deepseek-ai/dsh@0.1.0-rc.8 ./setup-dsh-server.sh
   ```

   `0.1.0-rc.8` satisfies the adapter's `^0.1.0-rc.6` ranges, so no exemption is needed at all.
   Reinstall the plugin afterwards if the profile was created on 0.2.x.

## Verify

```sh
systemctl status dsh                     # active (running)
journalctl -u dsh -n 50                  # no plugin load errors
curl -sS http://127.0.0.1:4310/ -o /dev/null -w '%{http_code}\n'
```

- Web: open `http://<lan-ip>:4310/` from the Mac, run a prompt that uses a tool (e.g. "list files in the workspace").
- Telegram: `/start`, then a prompt. `/new` starts a fresh session, `/status` reports the session.

## Security

- **The web UI is not internet-facing.** It listens on one concrete interface (wildcard binds are
  rejected by dsh) and holds an agent that can run shell commands on that box. LAN or Tailscale only.
- **The allowlist is the only gate on Telegram.** `allowedUserIds` empty means *everyone is rejected* —
  that's deliberate. Keep it to your id.
- `.env` is mode 600 in `DSH_HOME`; the bot token is the credential that lets anyone *call* the bot.
- If you later expose the web UI through a proxy, use `--public-url` + `--trusted-host` and put real
  auth in front of it; the runtime's token is not a user account.
- The agent runs as the unprivileged `dsh` user, not as root.

## Operating notes

| Task | Command |
|---|---|
| Logs | `journalctl -u dsh -f` |
| Restart | `sudo systemctl restart dsh` |
| Change allowlist/model | edit `/srv/dsh/home/profiles/web/cordis.patch.yml`, restart |
| Upgrade dsh | `sudo npm i -g @deepseek-ai/dsh@<ver>` then re-test both surfaces |
| Plugin logs | `/srv/dsh/home/profiles/web/.plugin-manager/logs/` |

Telegram chat→session mapping lives in the plugin's memory, so a restart loses the mapping but not
the sessions themselves: send `/new` after a restart, or continue in the web UI.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Bot silent, log says `botToken is empty` | token missing | set `DSH_TELEGRAM_BOT_TOKEN` in `.env`, restart |
| `⛔ You are not authorized` | your id not in `allowedUserIds` | add it, restart |
| `getUpdates: 401` | token revoked | new token from @BotFather |
| Plugin doesn't load | version gate not granted | re-run the script, check `journalctl` |
| `pnpm: command not found` during install | pnpm not on PATH | `sudo npm i -g pnpm`, re-run |
| Web UI loads but API calls fail | wrong host/token | use the printed `?token=` URL, or add `--trusted-host` |
