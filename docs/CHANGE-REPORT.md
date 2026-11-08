# Change report — setup `0.14.3` (and the 0.13.x UAT fixes)

Reviewer's summary of the autonomous work: the two host scripts are now one
`setup.sh` with an explicit command surface, the Penpot stack fixes from the
UAT are folded in, and the Telegram connector rework is specified but
deliberately **not** implemented yet (reasoning at the end).

Live deployment at the time of writing: **`0.2.1-rc.5-0.13.3`**. The last
section is the one action needed to move it to `0.14.3`.

---

## 1. One `setup.sh`

`install.sh` and `update.sh` are gone. `setup.sh` is the only entry point, and
every internal caller (updater service, smoke workflow, tests, docs) uses it.

| Command | Job |
|---|---|
| `setup.sh` / `setup.sh install` | install, or repair an existing deployment |
| `setup.sh update` | move to the newest compatible release |
| `setup.sh status` | versions, services, web, adapter, firewall |
| `setup.sh doctor [--fix]` | the shared health check |
| `setup.sh components list\|enable\|disable\|configure\|port` | Penpot stack |
| `setup.sh uninstall [--purge]` | remove services, keep data |
| `setup.sh help [command]` | the manual, one command at a time |

Common options: `--dir`, `--check`, `--yes`, `--config`, `--version`,
`-h/--help`. Update adds `--to` and `--allow-incompatible`; install keeps
`--design`, `--containers`, `--ref`, `--no-deps`, `--rotate-key`,
`--clean-source`; uninstall adds `--purge`.

The old flags are not silently accepted. Each one exits with the replacement:

```
--uninstall  → ./setup.sh uninstall
--purge      → ./setup.sh uninstall --purge
--doctor     → ./setup.sh doctor [--fix]
--fix        → ./setup.sh doctor --fix
--apply      → ./setup.sh update
--component  → ./setup.sh components …
--status     → ./setup.sh status
```

`--i-know-versions-are-incompatible` is still accepted by `update` because the
updater service's request contract names it; the documented spelling is now
`--allow-incompatible`.

### UX design notes (HIG-informed)

The HIG is written for Apple platforms, so this applies its principles through
the skill's web/CLI mapping rather than copying iOS chrome:

- **Purpose** — one verb per command; `install` is the default, so the file
  behaves like the old installer when run bare.
- **Agency** — every mutating command prints a plan first, `--check` is a real
  dry run, `--yes` is opt-in, and destructive uninstall asks for `yes` (and the
  path for `--purge`).
- **Familiarity** — verbs people already know (`install`, `update`, `status`,
  `doctor`, `uninstall`); the command name is the first word, flags after it.
- **Simplicity** — one file, one vocabulary, no deployment-mode flags. The
  plan and status use the same aligned `label: value` shape.
- **Feedback** — plan → numbered steps → a short summary with the next step;
  the doctor runs after every install and after every successful update.
- **Craft** — help is per command (`setup.sh help update`), not one wall of
  flags; errors name the command that fixes them.
- **Flexibility** — `--config` for unattended installs, `--yes` for scripts,
  `--json` for `status`, and prompts read `/dev/tty` when stdin is a pipe.
- **Responsibility** — secrets are never echoed, the provider key is kept on
  Enter, and a wrong `--dir` is refused before anything is deleted.

Accessibility through the terminal: status is never carried by colour alone
(`ok`/`warn`/`fail`/`==>` prefixes), the language is plain and actionable, and
non-interactive callers never block on a prompt.

### What was preserved

The install flow (plan, dependency plan, root re-run, git identity/credentials,
provider patch, env writing, systemd units, launchers, profile/plugin
bootstrap), the update flow (snapshots, tag policy, checkout, health gate,
rollback, doctor), the component flow, and uninstall. The merge is mechanical
where possible; the shared helpers (`set_env`, `prepare_penpot_*`,
`penpot_tls_hint`) are defined once.

### Internal callers updated

- `updater.mjs`: `setup.sh update --to …`, `setup.sh components …`; the
  cross-line flag is now `--allow-incompatible`.
- `native-smoke.yml`: `./setup.sh`, `./setup.sh update`, `./setup.sh uninstall`.
- CI: syntax check and every test file use `setup.sh`; the design TLS tests run
  in CI.
- Docs/README/AGENTS/UAT/UPGRADE/SELF-UPDATE/HOST/FIRST-RUN/CONTAINERS/PLUGINS/
  LIMITS/VERSIONS/DESIGN and the example env files.
- `repair.sh` comments and messages.

The **live updater migration** needs no shim: the old updater process runs the
old `update.sh` for the transition, the checkout removes that file, and the
running bash keeps its open file descriptor. The updater then exits and systemd
restarts it (`Restart=always`) with the new checkout, which calls `setup.sh`.

---

## 2. UAT fixes folded into the release

These were found while testing Penpot and are part of the same line:

| Release | Fix |
|---|---|
| `0.13.2` | profile `package.json` stored `name@version`, which pnpm rejects; the boot now repairs it and `pin_dependency` writes the bare version |
| `0.13.3` | `design/penpot.mjs` was not executable; git mode + installer chmod |
| `0.13.4` | design `data/assets` chowned to uid 1001 (export `io-exception`); images pinned to Penpot 2.18.6; truncated-token warning; doctor probes the token |
| `0.13.5` | CI-only test fix (runner is uid 1001) |
| `0.13.6` | HTTPS sidecar (`nginx:1.27-alpine`) + local CA + `design-tls.sh`; `design-tls` doctor check |
| `0.13.7` | update reconcile opens the TLS port in ufw |
| `0.13.8` | `design/certs` traversable so the CA can be `scp`'d |
| `0.14.0` | one `setup.sh` command surface (this work) |
| `0.14.1` | CI-only: the lone-download test clones a tag, not `main` |
| `0.14.2` | `uninstall` and `update` accept `--config` (the smoke workflow drives them from an answers file) |
| `0.14.3` | connector floor `0.14.0` (one command surface); setup pin/minimum raised |

The HTTPS front makes Penpot's token **Copy** button work (the clipboard API
needs a secure origin). The CA is generated once under `design/certs/`, the
server certificate is re-issued when the bind address changes, and `--doctor
--fix` now issues the certificate and reconciles a running stack, so a plain
update applies it without a component action.

---

## 3. Verification

- `node --test *.test.mjs` — **161/161 pass**.
- `bash -n setup.sh entrypoint.sh healthcheck.sh scripts/repair.sh
  scripts/design-tls.sh` — clean.
- `GITHUB_REF_NAME=v$(cat VERSION) node scripts/check-version.mjs` — ok.
- `node scripts/plugin-preflight.mjs --remote` — connector 0.13.1 and Penpot
  plugin 0.3.1 exist on npm with their tags.
- CI for `v0.2.1-rc.5-0.14.3` — **success**; Native smoke — **success**. The `0.14.0` tag's CI failed only on the lone-download test
  (fixed in `0.14.1`), and `0.14.1`'s smoke failed on `uninstall --config`
  (fixed in `0.14.2`).
- Detached-HEAD simulation (`git clone --branch v0.2.1-rc.5-0.14.3`) runs the
  installer tests green, which is the CI shape.
- The TLS sidecar was exercised locally: nginx started with a generated
  certificate and completed a TLS handshake (502 from the absent upstream, as
  expected).
- The live doctor currently reports the two known design problems
  (`design-assets 0:0`, `design-tls missing`) and a valid Penpot token.

---

## 4. Live deployment: one action

The host is still on `0.13.3`. Run:

```
/system update setup
```

It targets `0.14.3`. The transition is safe:

1. the old updater runs the old `update.sh`; it checks out `0.14.3` and restarts
   `dsh.service`;
2. the boot installs Penpot plugin `0.3.1` (floor raised) and repairs the
   profile;
3. `repair.sh --fix` (new) chowns `design/data/assets`, issues the HTTPS
   certificate and reconciles the running design stack;
4. the updater exits and reloads with the new code (`setup.sh`).

After it, the design stack is reachable at `https://192.168.2.98:8443/`.
Trust the CA once on the Mac:

```sh
scp <you>@192.168.2.98:/srv/dsh/design/certs/ca.crt ~/Downloads/dsh-penpot-ca.crt
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/Downloads/dsh-penpot-ca.crt
```

I did not trigger the update myself: it restarts the runtime that serves this
session, so the report would have been lost mid-write. The updater's drain path
is the normal no-SSH route.

---

## 5. Telegram connector `0.14.0` (implemented)

The proposal was approved and is now implemented in the connector repository:
**239/239 connector tests pass**, the connector CI is green, and
`dsh-telegram-connector@0.14.0` is published to npm with the `v0.14.0` tag. The
setup pins it in `plugins.json` (spec/fallback) and raises the floor to `0.14.0`
in setup `0.14.3`, so the next boot installs it.

### The new surface

- **`/menu` is the front door.** `/menu` — and `/start` in the bot chat — posts
  the control card: **Status · Workspaces · Web link · Help · Update setup ·
  Restart · Plugins · Components**. Buttons run the same handlers as the typed
  commands; deployment buttons stay admin-only.
- **`/plugins` is one group**: `list | info | add | remove | enable | disable |
  confirm | cancel | approve`. `/plugin` replies with the new spelling.
- **`/components`** replaces `/system components`, matching `setup.sh
  components`.
- **`/status` in the bot chat is `/system status`.** The dashboard keeps
  `/status` for its workspace/session state.
- **The alias table is gone**: `/start`, `/?`, `/man`, `/plugin
  list|install|rm|del`, `/list`, `/workspace rm`. `/man` is removed; `/help`
  and `<command> --help` remain.
- **`/dashboard` keeps its topic role** (claim an empty topic); the control card
  is `/menu`.
- The help registry, README, `docs/COMMANDS.md` and the tests follow the new
  surface.

### Migration

- Old spellings are not aliases. `/plugin` and `/system components` reply with
  the new command instead of failing silently.
- `/system update connector` still moves the connector independently; the setup
  release only raises the floor, so a newer compatible connector installed from
  the bot survives a reboot.
- No data or bindings change: the command surface moved, the stored sessions,
  topics and settings are untouched.

## 6. Open items / notes

- `0.14.0`'s tag CI and `0.14.1`'s smoke were red for test/workflow reasons;
  `0.14.2` was green, and `0.14.3` adds the connector floor.
- The Penpot images are pinned to `2.18.6`; the running stack is already that
  version, and the reconcile applies the pin on the next `up -d`.
- `--i-know-versions-are-incompatible` is retained only for the updater's
  existing request contract; docs use `--allow-incompatible`.
- The design stack still serves plain HTTP on `8090` for the agent; only the
  browser uses `8443`. Changing the bind address re-issues the server
  certificate but keeps the trusted CA.
- UAT of the Penpot plugin tools (list/search/inspect/export/import) is still
  pending on the updated deployment; the API-layer fixes are in `0.3.1`.
