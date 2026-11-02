# Design stack (optional)

Penpot — the self-hosted design tool — plus a small `penpot` CLI inside the
runtime, so the agent can read, export and import design files without a browser
and without third-party code in the image.

The stack is **opt-in** and separate from the runtime:

```
runtime ──penpot CLI──HTTP──► design-frontend ──► design-backend ──► postgres / redis
                                 └──────────────► design-exporter
```

It is its own compose project (`design/compose.yaml`, project `dsh-design`) with
its own data under `design/data/`. Removing it does not touch the runtime.

## Install

```sh
./install.sh --design docker          # add the stack
./install.sh --design none            # skip it (the default when unattended)
```

Interactive installs ask once. Re-running `install.sh` later is how you **add it
afterwards**: the answers already in `.env` are preserved.

In **native mode** the stack is still Docker: Penpot has no supported machine
install. `install.sh` skips it with a warning when Docker is absent.

## First run

1. Open `http://<DSH_BIND_IP>:<DSH_DESIGN_PORT>/` and create the first account
   (registration is on; email verification is off, a LAN instance has no SMTP).
2. Settings → **Access tokens** → create one.
3. Put it in `design/.env` as `PENPOT_ACCESS_TOKEN=...`.
4. Re-run the component once so the runtime picks the token up: `/system manage`
   → Enable (idempotent), or `./update.sh --component design enable`.

## Managing it from the control chat

`/system manage` posts a card with one row per component: Enable / Disable / Port.
The updater applies the change on the host, restarts the runtime and reports.
`/system manage design port 8091` does the same without a tap.

The runtime reaches Penpot as `http://design-frontend:8080` over the shared
`dsh-design` network — no published port, no host firewall in the path. The
published port exists for your browser only. The health probe after a change is
advisory: if it cannot reach the service it prints the container states and
still reports the change as applied.

Changing the port is state-aware: on a stopped stack it only saves the value
(nothing is started), and on a running stack the containers are recreated on the
new port. Disable stops the stack and keeps `design/data/`. The runtime env keeps
`PENPOT_API_URL` but the token is cleared, so the CLI fails closed.

## The plugin

Enabling the component also installs the DSH plugin
[dsh-penpot-plugin](https://github.com/vladtsvirko/dsh-penpot-plugin) into the
profile: the entrypoint runs `dsh plugin --profile web add <ref>` on the next
boot, where `<ref>` is `PENPOT_PLUGIN_REF` (pinned in `components.json`,
overridable in `.env`) and writes a managed `dsh-penpot` row. Disabling sets
`PENPOT_ENABLED=0`, which leaves the package installed but disables the row.

The plugin is versioned on its own: bumping it means bumping the ref in
`components.json`, which is a setup release.

## The `penpot` CLI

Shipped in the image at `/usr/local/bin/penpot` (native: symlinked from the
checkout). One dependency-free Node file, MIT like the rest of the repo.

```sh
penpot whoami
penpot teams
penpot projects [--team <id>]
penpot files <project-id>
penpot search <term>
penpot summary <file-id>
penpot export <file-id> design.penpot
penpot import design.penpot --project <project-id> [--name "New name"]
penpot import design.penpot --into <file-id>     # in-place, binfile-v3
```

Auth comes from the environment: `PENPOT_API_URL` (the stack's origin) and
`PENPOT_ACCESS_TOKEN`. Both are written into the runtime `.env` when the
component is enabled, so the agent calls the CLI from its bash tool directly.

`--json` prints the raw payload. Exit codes: `0` ok, `1` usage or environment,
`2` the API refused the request.

### The round-trip

`export` writes a `.penpot` file — a ZIP of the design's JSON. The agent can
unzip it, read or edit the JSON with its usual tools, and `import` it back as a
new file, or in place with `--into` on binfile-v3. That is deliberate: Penpot's
write API needs its own change format (`update-file`) with add/mod/touched
operations, and reimplementing that is a project, not a wrapper.

## Limits

- **No live canvas.** The CLI reads and writes files; it cannot watch a designer
  work or comment in real time.
- **In-place import requires binfile-v3** (Penpot ≥ 2.x) and a file produced by
  `export`; Penpot refuses other shapes.
- The multipart field names for `import-binfile` follow Penpot's own frontend.
  They are tested against a fake server here and need one real run on your
  instance.
- The token is a credential: anyone with it can read and rewrite every design
  the account can reach. Use a dedicated account scoped to one team.

## Data, backup, removal

- `design/data/postgres` — the design database.
- `design/data/assets` — uploaded images and fonts.
- Backup: stop the stack and copy `design/data/`, or `pg_dump` from the
  `design-postgres` service.

```sh
docker compose --project-directory design -f design/compose.yaml down
```

`down -v` plus deleting `design/data/` removes everything; then set `DESIGN=none`
in the main `.env` and restart the runtime.

## Why no MCP server

The shortcuts were all worse. The popular Penpot MCP servers carry **no license**
(unusable in an MIT repository); one licensed alternative needs direct Postgres
access, which is more privilege than a token; the official MCP is MPL-2.0 and
clean, but it drives a Penpot browser tab through a plugin — the least reliable
thing to put in a tool path. A CLI plus the `.penpot` round-trip covers the work
without any of that.
