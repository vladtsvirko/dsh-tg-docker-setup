# Branch notes — `feat/standalone-plugins`

Status of the three same-named branches. Written for the review pass; delete it
once the release is tagged.

| Repository | Branch | Version | Commit |
|---|---|---|---|
| `dsh-tg-docker-setup` | `feat/standalone-plugins` | `0.2.1-rc.5-0.13.0` | branch head (this file) |
| `dsh-telegram-connector` | `feat/standalone-plugins` | `0.13.0` | branch head |
| `dsh-penpot-plugin` | `feat/standalone-plugins` | `0.3.0` | branch head |

Nothing is tagged or merged. `main` is untouched.

## Done

### Standalone review

- Installed both plugins into a throwaway `DSH_HOME` with `dsh plugin add
  link:<checkout>`, composed the profile with `dsh --profile web --dump-config`,
  and booted it (`dsh --profile web`, fake bot token).
- **Found and fixed a load-blocking Penpot bug:** `ctx.tools` was used without
  `inject = ['tools']`. Cordis refuses that property, so the plugin failed to
  mount in a plain profile. The setup path masked it while the plugin happened
  not to be mounted.
- **Fixed the Penpot bundle patch:** it still passed `backend: auto` and
  `mcpServer`, removed in 0.2.0.
- **Added `penpot_import`**, the export counterpart the README already promised.
- Connector bundle patch now reads `DSH_TELEGRAM_BOT_TOKEN`, `ALLOWED_USER_IDS`,
  `DSH_ADMIN_USER_ID`, `DSH_PROVIDER`, `DSH_MODEL` and `DSH_WORKSPACE`, so a
  bare install needs no patch edit.
- Wrote `docs/STANDALONE.md` in both plugin repos and `docs/PLUGINS.md` in the
  setup, including the capability matrix (what the setup adds vs. what the
  plugin does).

### Independent versioning

- Connector and Penpot use plain semver and their own `AGENTS.md`; DSH
  compatibility lives in `COMPATIBILITY.md`, not in the version string.
- Setup `plugins.json` pins a recommended `ref` and a `minimum` per plugin.
- Entrypoint rule: install the ref when absent, enforce the minimum, never
  downgrade. A legacy `.env` pin below the minimum is overridden by the catalog
  ref with a warning.
- `reset-plugin` preserves the installed specs (and removes the previous
  package when the connector is switched), so a repair does not downgrade a
  bot-updated plugin.
- `components.json` no longer carries `plugin.ref`; installer/updater read
  `plugins.json`.
- Release rules, `docs/VERSIONS.md`, README, LIMITS, SELF-UPDATE, UPDATER,
  UPGRADE, HOST, UAT and CI were updated. CI no longer requires a connector tag
  matching the setup tag; it validates the catalog instead.

### Updates from Telegram

- `/system update connector [to <version>] [now]`: resolves the newest tag,
  checks the tag's declared DSH range, passes the exact ref to the supervisor,
  installs it through `reset-plugin` inside a trial.
- `/system update penpot [to <version>] [now]` and `/system update plugin <name>
  [to <version>] [now]`: resolve the bundle's tag, open a trial, remove the old
  package, install the new one through the plugin manager, restore the previous
  spec if install fails, and fall back to a supervisor rollback if restoration
  fails.
- Supervisor `/update` accepts and validates `ref`, passes
  `DSH_PLUGIN_TARGET_REF` to the entrypoint, and the entrypoint fails the update
  hard so the supervisor restores immediately instead of booting without a bot.

### GitHub `dsh-plugin` topic

- Confirmed the upstream line: the topic is GitHub repository metadata (the
  About box), not a file. Neither repository had any topics.
- Added a maintainer instruction to both plugin `AGENTS.md`.
- **Not set yet:** the available GitHub token can read the repositories but
  returns 403 on `PATCH /repos/...` and `PUT /repos/.../topics` (no repository
  administration permission). See “Pending decisions”.

## Verification

Run and green:

```sh
# connector
npm run typecheck && npm test && npm run build          # 232 passed, 1 todo
# penpot
npm run typecheck && npm test && npm run build          # 11 passed
# setup
node --test entrypoint.test.mjs supervisor.test.mjs plugins.test.mjs install.test.mjs update.test.mjs
bash -n update.sh install.sh entrypoint.sh healthcheck.sh scripts/repair.sh
GITHUB_REF_NAME=v0.2.1-rc.5-0.13.0 node scripts/check-version.mjs
node scripts/plugin-preflight.mjs            # local versions match the pins
node scripts/plugin-preflight.mjs --remote   # fails until the plugin tags exist
./install.sh --check --yes --dir /tmp/x      # plan still resolves (no writes)

# both packages
npm pack --dry-run  # lib/, cordis.patch.yml, COMPATIBILITY.md, docs/STANDALONE.md
```

Standalone check (both plugins composed and booted in a temp `DSH_HOME`):
no mount errors, connector reached Telegram with a fake token (401 expected),
Penpot registered its tools.

## Decisions (2026-11-05)

- **Plugin versions are plain semver.** Only the setup keeps the
  `<dsh-version>-<product>` prefix. The current proposals are the next minor,
  not `1.0.0`: connector `0.13.0`, Penpot `0.3.0`, setup `0.13.0`.
- **npm waits for `1.0.0`.** Until then both plugins are distributed as GitHub
  tags and updated from tags; no registry path is added to the resolver.
- **Update channel:** newest tag. Stable/prerelease channels stay a follow-up.
- **Release owner:** merge to the default branch (GitHub calls it `main`; the
  discussion said "master"), cut the tags, then UAT on the owner's box.

## Remaining actions

1. **Merge and tag (owner).** No tags exist yet; the branches are review-only.
   ```sh
   # each repository, in this order
   git switch main
   git merge --no-ff feat/standalone-plugins
   git push

   # connector first
   git tag v0.13.0 && git push origin v0.13.0
   # then Penpot
   git tag v0.3.0 && git push origin v0.3.0
   # prove the pins resolve before tagging the setup
   cd dsh-tg-docker-setup && node scripts/plugin-preflight.mjs --remote

   # setup last
   git tag v0.2.1-rc.5-0.13.0 && git push origin v0.2.1-rc.5-0.13.0
   ```
   `plugin-preflight.mjs --remote` currently fails with “has no tag … — push the
   plugin tag before the setup tag”; that is expected before the plugin tags and
   must be green before the setup tag.

2. **Set the GitHub topics.** `scripts/github-topics.mjs --check` shows the
   current state and exits 1 while they are missing. To set them, run the same
   script with a token that has repository administration:
   ```sh
   GITHUB_TOKEN=... node scripts/github-topics.mjs
   ```
   The runtime's git-push token is fine-grained and returns 403 on the topics
   endpoint (`Resource not accessible by personal access token`). The GitHub UI,
   `gh repo edit --add-topic`, or an admin-scoped token works. The connector
   description is also empty on GitHub; a PATCH or the About box can fill it.

3. **UAT on the owner's box.** The unit/integration suite covers discovery,
   range checks, argument parsing, the supervisor ref hand-off and the plugin
   manager sequence. Still manual: a real Telegram update of the connector and
   of Penpot, a live Penpot 2.18.6 import round trip, and the first boot after
   the setup tag (which enforces the new floors).


## Live deployment

The running deployment was not touched. It still runs setup `0.12.9`/connector
`0.12.9` with Penpot plugin `0.1.2`; the next setup update will enforce the new
floors and install `0.13.0`/`0.3.0` once those tags exist.
