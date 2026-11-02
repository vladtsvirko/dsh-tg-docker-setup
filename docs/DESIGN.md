# Design stack (optional)

Penpot — the self-hosted design tool — plus a headless MCP bridge, so the agent
can read and write design files as tools instead of round-tripping screenshots.

The stack is **opt-in** and separate from the runtime:

```
runtime  ──MCP (HTTP)──►  design-mcp  ──Penpot API──►  design-frontend
                                                     design-backend ──► postgres / redis
```

It is its own compose project (`design/compose.yaml`, project `dsh-design`) with
its own data under `design/data/`. Removing it does not touch the runtime.

## Install

```sh
./install.sh --design docker          # ask nothing else; adds the stack
./install.sh --design none            # skip it (the default when unattended)
```

Interactive installs ask once. Re-running `install.sh` later is how you **add it
afterwards** — the answers already in `.env` are preserved, so it is a repair,
not a reinstall.

Once installed, the stack is managed from the control chat: `/system manage` posts
a card with Enable / Disable / Port for every component in `components.json`. The
updater applies the change and restarts the runtime so the tools follow.

In **native mode** the stack is still Docker: Penpot has no supported
machine install (Clojure backend, ClojureScript frontend, a Chromium-based
exporter). `install.sh` skips the stack with a warning when Docker is absent and
leaves the rest working.

## First run

1. Open `http://<DSH_BIND_IP>:<DSH_DESIGN_PORT>/` and create the first account
   (registration is enabled; email verification is off, a LAN instance has no
   SMTP).
2. Settings → **Access tokens** → create one.
3. Put it in `design/.env` as `PENPOT_ACCESS_TOKEN=...`.
4. Restart the runtime (`/system restart` or `docker compose restart dsh`).

On boot the entrypoint writes one managed row into the profile:

```yaml
- insert:
    - id: mcp-penpot
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        transport: streamable-http
        serverName: penpot
        url: 'http://host.docker.internal:4401/mcp'
        failOnStartupError: false
```

The agent then has `mcp__penpot__*` tools: projects, files, pages, shapes,
components, export. `failOnStartupError: false` means a missing or tokenless
MCP server never blocks the runtime from booting.

## Configuration

| Key | Where | Meaning |
|---|---|---|
| `DSH_DESIGN_PORT` | main `.env` | Penpot port, published on `DSH_BIND_IP` only |
| `DSH_DESIGN_MCP_PORT` | main `.env` | loopback port for the MCP bridge (default `4401`) |
| `DSH_DESIGN_ENABLED` | main `.env` | `1` writes the MCP row on boot |
| `DSH_DESIGN_MCP_URL` | main `.env` | what the runtime dials (`host.docker.internal` in Docker mode, `127.0.0.1` natively) |
| `PENPOT_ACCESS_TOKEN` | `design/.env` | the agent's credential for Penpot |
| `PENPOT_DB_PASSWORD`, `PENPOT_SECRET_KEY` | `design/.env` | generated on first install |

Change the port in the main `.env` and re-run `./install.sh --design docker`.

## Data, backup, removal

- `design/data/postgres` — the design database.
- `design/data/assets` — uploaded images and fonts.
- Backup: stop the stack and copy `design/data/`, or `pg_dump` from the
  `design-postgres` service.

```sh
docker compose --project-directory design -f design/compose.yaml down
```

`down -v` plus deleting `design/data/` removes everything. Then set
`DESIGN=none` in the main `.env` and restart the runtime to drop the MCP tools.

## Resources and security

- Roughly 2–3 GB RAM and 1–2 CPUs for five containers; Penpot's exporter runs
  Chromium.
- Published on `DSH_BIND_IP` only — never `0.0.0.0`, the same rule as the web UI.
- If you expose it beyond the LAN, put TLS in front and turn registration off
  (`PENPOT_FLAGS` in `design/compose.yaml`).
- The access token is a credential: anyone with it can read and modify every
  design the account can reach. Keep `design/.env` at `0600`.

## Why the bridge is built locally

Upstream publishes `ghcr.io/zcube/penpot-mcp-server`, but that package is not
publicly pullable (anonymous manifest requests are denied), so the stack builds
it from a pinned commit with `design/mcp.Dockerfile`. The pin is
`MCP_REF`, defaulting to a commit in the file; change it deliberately, never by
moving to `latest`. CI builds the image and starts it on every change under
`design/`.

## Why an MCP bridge

The official Penpot MCP is driven by a browser plugin: a human keeps a Penpot
tab open and clicks "Connect". That is unusable from a headless runtime, so the
stack ships the community HTTP MCP server
(`ghcr.io/zcube/penpot-mcp-server`), which talks to Penpot's API with an access
token and needs no browser.

If that server drifts or proves incomplete, the fallback is our own client over
the same API: the profile row, the URL and the token stay the same.
