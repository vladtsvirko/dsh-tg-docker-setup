# Plugins: standalone and in the setup

Both plugins are products in their own right. The setup installs and supervises
them, but neither imports the setup, reads its checkout, or needs its services.
This page is the contract: what works with the setup, what works without it, and
where the boundary is.

| | Connector | Penpot plugin |
|---|---|---|
| Repository | `dsh-telegram-connector` | `dsh-penpot-plugin` |
| Current version | `0.15.1` | `0.4.6` |
| Standalone guide | [docs/STANDALONE.md](https://github.com/vladtsvirko/dsh-telegram-connector/blob/main/docs/STANDALONE.md) | [docs/STANDALONE.md](https://github.com/vladtsvirko/dsh-penpot-plugin/blob/main/docs/STANDALONE.md) |
| Install | `dsh plugin --profile <p> add dsh-telegram-connector@0.15.1` | `dsh plugin --profile <p> add dsh-penpot-plugin@0.4.6` |
| Bundle patch | mounts the connector row, token from env | mounts `dsh-penpot`, URL/token from env |
| UI configuration | Plugins → **Configure**: bot token, allowed ids, admin id | Plugins → **Configure**: API URL, token |
| Setup extras | supervisor, updater, components, firewall, managed row | Penpot/Podman stack, `penpot` CLI, managed row |
| UI-managed setup | `setup.sh install --plugins none` (legacy `ui`) skips both installs; install them from the Plugins page | same |

The installer asks whether to add the suggested plugins: the Telegram connector
by default, plus the Penpot plugin when the Penpot stack is enabled. Answering
no is UI-managed mode; `--plugins suggested|none` sets it unattended.

In UI-managed mode the setup installs nothing: the Plugins page uses DSH's own
plugin manager, which installs the latest published npm release and updates it
independently of the setup tag. Setup-managed mode is the pinned path
(`plugins.json`); pick it only when a deployment must be reproducible.

## The test

A plugin passes the standalone test when **all** of its model-facing capability
works in a plain DSH profile, and the setup only adds packaging or lifecycle. A
plugin fails when a tool or command silently depends on a setup path, service or
environment variable.

Review result:

- **Penpot plugin — passes.** Its eight tools talk to Penpot over HTTP RPC; the
  only host requirement is the DSH tool registry. The setup adds a Penpot
  container, a token, and a managed row. The bundle patch had drifted (it still
  passed `backend`/`mcpServer`, removed in 0.2.0); that is fixed in 0.3.0. Import,
  which the README promised but no tool exposed, is now `penpot_import`.
- **Connector — passes.** Sessions, topics, media, reactions, the workspace
  dashboard and `/plugins` work in any base-backed profile. Supervisor,
  updater, components and firewall are optional services; each command says what
  is missing instead of failing. Standalone mode is documented, and the
  self-update path now resolves tags instead of relying on the setup version.
- **The setup — adds lifecycle, not capability.** It installs the plugins,
  writes managed rows, runs trials, and restarts the runtime. It never patches a
  plugin's code or adds a tool.

The review found and fixed two standalone defects in the Penpot plugin: the
bundle patch still carried the removed `backend`/`mcpServer` keys, and the code
used `ctx.tools` without `inject = ['tools']`, which Cordis refuses at load time
(`cannot get property "tools" without inject`). The second one made a plain
profile fail to mount the plugin; the setup masked it only while the plugin was
not mounted.

## Verification

Both plugins were installed into a throwaway `DSH_HOME` with `dsh plugin add
link:<checkout>` and composed with `dsh --profile web --dump-config`; both rows
appeared with their environment-driven config. A real boot of that profile then
loaded both plugins without a mount error (the connector used a fake token, so
Telegram answered 401 — expected). This is the check to repeat after a change
that touches `inject`, the bundle patch or a config schema.

Automated coverage: `entrypoint.test.mjs` (floor, explicit target, reset) and the
connector's `tests/updates.integration.test.ts` (the update commands through the
real handlers with a fake plugin manager).

## Update model

`plugins.json` carries a fallback spec, a GitHub fallback and a minimum:

- **Fresh install / repair (suggested):** resolve npm `latest` at install time
  and pin the installed version. If the registry cannot be reached, install
  `spec` from npm or the same release from `fallback` on GitHub.
- **Boot:** if the installed version is below `minimum`, reinstall; otherwise
  leave it. A newer version installed from the bot is never downgraded. A
  legacy `.env` pin below `minimum` is overridden by the catalog spec. An
  explicit `DSH_TELEGRAM_PLUGIN`/`PENPOT_PLUGIN_REF` pin opts out of latest for
  that package.
- **Update from Telegram:**
  - `/system update connector [to <version>] [now]` resolves the newest npm
    version (or the repository tag for a GitHub-installed connector), checks
    its declared DSH range, and lets the supervisor install that exact spec in
    a trial.
  - `/system update penpot [to <version>] [now]` and
    `/system update plugin <name> [to <version>] [now]` remove and reinstall the
    bundle through the host plugin manager, in a trial, restoring the previous
    version if the new one fails.
- **Standalone:** install `dsh-penpot-plugin@<version>` or
  `dsh-telegram-connector@<version>`; update with `dsh plugin remove` then
  `add`. The same commands explain the supervisor/updater limits.
- **Publishing:** a plugin tag runs its `publish.yml`, which tests, validates the
  tag and publishes that exact version to npm with provenance. Authentication is
  npm Trusted Publishing (GitHub OIDC), so no npm token is stored. The first
  version of a new package is published manually once; configure the trusted
  publisher for the repository and `publish.yml` immediately after.

Plugin versions are independent of the setup `VERSION`. See
[`VERSIONS.md`](VERSIONS.md).

## Discoverability

The upstream DSH README asks plugin repositories to carry the GitHub topic
`dsh-plugin`; GitHub topics are repository metadata (the "About" box), not a
file in the repository. Both plugin repositories carry it, plus product topics
(`deepseek-harness`, `telegram` / `penpot`). The setup repository is not a
plugin and does not carry it.

`scripts/github-topics.mjs --check` verifies the state; both repositories are
green as of 2026-11-05. Applying it needs a token with repository
administration, so the deployment token was granted that permission once.

## What is deliberately not shared

| Concern | Owner |
|---|---|
| Telegram polling, sessions, topics | connector |
| Penpot RPC and tool schemas | Penpot plugin |
| Supervised restarts, profile snapshots | setup (`supervisor.mjs`) |
| Setup checkout, DSH install, health gate | setup (`setup.sh update`, `updater.mjs`) |
| Plugin tags and compatibility rows | each plugin repository |
| Recommended pins and floors | setup (`plugins.json`) |

A plugin change never requires a setup release. A setup release raises a
plugin `minimum` only when it depends on new plugin behaviour.
