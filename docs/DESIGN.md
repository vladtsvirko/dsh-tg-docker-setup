# Design stack (optional)

Penpot — the self-hosted design tool — plus a small dependency-free `penpot` CLI
in the deployment, so the agent can read, export and import design files without
a browser.

The stack is **opt-in** and separate from the runtime:

```
runtime (penpot CLI) ──HTTP──► penpot-frontend ──► penpot-backend ──► postgres / redis
                                     └───────────► penpot-exporter
```

The runtime calls the frontend on its published address
(`DSH_BIND_IP:DSH_DESIGN_PORT`). It is its own compose project
(`design/compose.yaml`) with its own data under
`design/data/`. Removing it does not touch the runtime.

## Install

```sh
./install.sh --design penpot          # add the stack
./install.sh --design none            # skip it (the default when unattended)
```

Interactive installs ask once. Re-running `install.sh` later is how you **add it
afterwards**: the answers already in `.env` are preserved.

The stack always runs on Podman: Penpot has no supported machine install. The
updater runs it rootful (the Penpot images need normal container networking),
while the agent's own containers are rootless. `install.sh` skips the stack with
a warning when Podman is absent, and the runtime keeps working without it.

## Firewall

Podman does **not** bypass ufw the way Docker does. When ufw is active, the
installer (and `update.sh --component design enable`) adds the three rules the
stack needs:

```sh
ufw allow in on <podman-bridge>
ufw route allow in on <podman-bridge> out on <podman-bridge>
ufw route allow in on <LAN-interface> out on <podman-bridge>
ufw allow from <LAN> to any port <DSH_DESIGN_PORT> proto tcp
```

The LAN-interface route is what lets a remote browser reach the DNAT'd
container port; without it `localhost` works and the LAN times out. Without the
bridge rules the containers cannot resolve each other through `aardvark-dns`,
so the frontend fails with `host not found in upstream "penpot-backend"` and the
backend with `UnknownHostException: penpot-postgres`. The rules are not removed
by `install.sh --uninstall`; delete them with `ufw delete` if you remove the
stack.

## First run

1. Open `http://<DSH_BIND_IP>:<DSH_DESIGN_PORT>/` and create the first account
   (registration is on; email verification is off, a LAN instance has no SMTP).
2. Settings → **Access tokens** → create one.
3. The host tools ask for it: `./install.sh`, `./update.sh --apply` and
   `./update.sh --component design enable` write the token to
   `/srv/dsh/design/.env` and mirror it into `/srv/dsh/.env`. Enter keeps the
   stored token, so a re-run never requires entering it again.
4. On a first install the stack is not up yet when the prompt appears, so leave
   it blank; once the account exists, re-run `./update.sh --component design
   enable` (or `./install.sh`) and paste it. From Telegram, `/system components`
   → Enable reuses the stored token — the bot never asks for secrets.

## Managing it from the control chat

`/system components` posts a card with one row per component: Enable / Disable / Port.
The updater applies the change on the host, restarts the runtime and reports.
`/system components design port 8091` does the same without a tap.

The runtime reaches Penpot at `PENPOT_API_URL=http://<DSH_BIND_IP>:<DSH_DESIGN_PORT>`,
the published frontend port — the same address your browser opens. There is no
shared container network between the runtime and the stack: the CLI is a host
process and goes over the published port, so a host firewall that blocks the
port also blocks the CLI. The health probe after a change is advisory: if it
cannot reach the service it prints the compose service states and still reports
the change as applied.

Changing the port is state-aware: on a stopped stack it only saves the value
(nothing is started), and on a running stack the containers are recreated on the
new port. Disable stops the stack and keeps `design/data/`. The runtime env keeps
`PENPOT_API_URL` but the token is cleared, so the CLI fails closed.

## The plugin

Enabling the component also installs the DSH plugin
[dsh-penpot-plugin](https://github.com/vladtsvirko/dsh-penpot-plugin) into the
profile: the entrypoint runs `dsh plugin --profile web add <spec>` on the next
boot, where `<spec>` is `PENPOT_PLUGIN_REF` (pinned in `plugins.json`,
overridable in `.env`) and writes a managed `dsh-penpot` row. Disabling sets
`PENPOT_ENABLED=0`, which leaves the package installed but disables the row.

The plugin is versioned on its own. `plugins.json` pins an exact npm spec, a
GitHub fallback of the same release, and a minimum; a newer compatible version
installed from the bot stays installed, and a setup release only raises the
floor when it needs newer plugin behaviour.

## The `penpot` CLI

Symlinked from the checkout at `/usr/local/bin/penpot` by the installer. One
dependency-free Node file, MIT like the rest of the repo.

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
`PENPOT_ACCESS_TOKEN`. Both are written into `/srv/dsh/.env` when the component
is enabled, so the agent calls the CLI from its bash tool directly.

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
  `penpot-postgres` service.

```sh
(cd design && podman-compose -f compose.yaml down)
```

`down -v` plus deleting `design/data/` removes everything; then set `DESIGN=none`
in `/srv/dsh/.env` and `sudo systemctl restart dsh.service`.

## Why no MCP server

The shortcuts were all worse. The popular Penpot MCP servers carry **no license**
(unusable in an MIT repository); one licensed alternative needs direct Postgres
access, which is more privilege than a token; the official MCP is MPL-2.0 and
clean, but it drives a Penpot browser tab through a plugin — the least reliable
thing to put in a tool path. A CLI plus the `.penpot` round-trip covers the work
without any of that.
