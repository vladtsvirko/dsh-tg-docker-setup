# Change report — setup `0.14.2` (and the 0.13.x UAT fixes)

Reviewer's summary of the autonomous work: the two host scripts are now one
`setup.sh` with an explicit command surface, the Penpot stack fixes from the
UAT are folded in, and the Telegram connector rework is specified but
deliberately **not** implemented yet (reasoning at the end).

Live deployment at the time of writing: **`0.2.1-rc.5-0.13.3`**. The last
section is the one action needed to move it to `0.14.2`.

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
- CI for `v0.2.1-rc.5-0.14.2` — **success**; the Native smoke workflow —
  **success**. The `0.14.0` tag's CI failed only on the lone-download test
  (fixed in `0.14.1`), and `0.14.1`'s smoke failed on `uninstall --config`
  (fixed in `0.14.2`).
- Detached-HEAD simulation (`git clone --branch v0.2.1-rc.5-0.14.2`) runs the
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

It targets `0.14.2`. The transition is safe:

1. the old updater runs the old `update.sh`; it checks out `0.14.2` and restarts
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

## 5. Telegram connector: proposal, not implemented

The connector (`0.13.1`, ~11.6k lines) works and is heavily tested. A command
surface rewrite during the setup merge would have mixed two large risks, so I
reviewed it and left the implementation for a dedicated change. The proposal:

### Current surface

Three surfaces (control chat, workspace dashboard, session topic), ~40 command
paths, plus an alias table (`/start`, `/?`, `/help`, `/plugin list|install|rm|del`,
`/list`, `/list archived`, `/workspace rm`). `/status` and `/system status`
overlap; `/plugins` and `/plugin` overlap; `/dashboard` is already a button
card but `/start` still dumps the manual.

### Proposed `0.14.0` connector

1. **`/menu` is the front door** (and `/start` posts it in the control chat): a
   single card with buttons — **Status**, **Workspaces**, **New workspace**,
   **Plugins**, **System**, **Web link**, **Help**. Each button calls the same
   handler as its command; admin-only buttons are omitted for non-admins.
   This is the HIG "buttons over commands" translation.
2. **Remove the alias table.** `/help` and `<command> --help` stay; `/help`,
   `/start`-as-alias and the `/plugin`/`/workspace` short forms go. `/start`
   remains only as the welcome card and the `startgroup` deep link.
3. **One status.** Keep `/system status` as the detailed card; `/status` becomes
   an alias or is removed. The dashboard card shows the same fields.
4. **`/plugins` becomes the group** (`/plugins list|add|remove|enable|disable|info`)
   and `/plugin` goes away.
5. **`/components`** replaces `/components`, matching `setup.sh
   components`.
6. **Cards over prose** for the remaining actions: every confirmation is a card
   with a verb button and **Cancel**; errors name the command that fixes them.

### Why deferred

- The connector has its own release track and test suite; a command rewrite
  needs its own UAT window.
- The current surface works; the setup merge already changes the updater's
  script contract, and changing both at once would make a rollback ambiguous.
- The proposal is breaking, so it is a connector `0.14.0` (and a setup `minimum`
  bump), not a patch.

Next step: implement it as a dedicated connector branch, with the existing
`help.ts` registry as the single source of truth and the `/menu` callbacks
routed through the same handlers, then bump the setup's `plugins.json` floor.

---

## 6. Open items / notes

- `0.14.0`'s tag CI and `0.14.1`'s smoke are red for the two test/workflow
  reasons above; `0.14.2` is the tag to deploy (CI and smoke green).
- The Penpot images are pinned to `2.18.6`; the running stack is already that
  version, and the reconcile applies the pin on the next `up -d`.
- `--i-know-versions-are-incompatible` is retained only for the updater's
  existing request contract; docs use `--allow-incompatible`.
- The design stack still serves plain HTTP on `8090` for the agent; only the
  browser uses `8443`. Changing the bind address re-issues the server
  certificate but keeps the trusted CA.
- UAT of the Penpot plugin tools (list/search/inspect/export/import) is still
  pending on the updated deployment; the API-layer fixes are in `0.3.1`.
