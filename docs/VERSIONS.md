# Versions and update policy

Three artifacts, two release tracks:

| Artifact | Repository | Version | Released with |
|---|---|---|---|
| setup | `dsh-tg-docker-setup` | `0.2.1-rc.5-0.13.5` | DSH, as one tag |
| connector | `dsh-telegram-connector` | `0.13.1` | its own tag |
| Penpot plugin | `dsh-penpot-plugin` | `0.3.1` | its own tag |

The setup is released as one unit with DSH. Each plugin is released on its own
and pinned by the setup's `plugins.json`; plugin tags do not match the setup tag
and do not have to.

## Setup scheme

```
<dsh-version>-<major>.<minor>.<patch>          tag: v<same>
v0.2.1-rc.5-0.13.5
```

- **DSH part** (`0.2.1-rc.5`) is the exact DSH release the setup was built and
  tested against. Prerelease suffixes are part of the version.
- **Product part** (`0.13.5`) is ours.
  - It resets to `0.0.0` when the setup aligns to a new DSH line.
  - `0.x` is the compatible line. A patch is a fix, a minor is a compatible
    feature, and `1.0.0` (or any new major) marks an incompatible change.
  - Never ship a breaking change in the `0.x` line.
- The tag and `VERSION` must agree; the DSH part is the prefix of `VERSION` and
  `install.sh` installs `@deepseek-ai/dsh@<DSH part>`. There is no `.env` DSH
  pin.

## Plugin scheme

Plain semver, one tag per plugin repository:

```
<major>.<minor>.<patch>        tag: v<same>
```

- `0.x` is the compatible line; `1.0.0` marks a break.
- `COMPATIBILITY.md` in the plugin repository states which DSH release was
  tested. It is not encoded in the version.
- `peerDependencies` is the supported DSH range. `/system update` reads the
  range from the published manifest (or the tagged `package.json` for a git
  install) and refuses a version the running runtime does not satisfy.
- Tags and published versions are immutable. Every tag is a release: the
  publish workflow uploads that exact version, and nothing is published from
  `main` directly.
- Distribution is npm (`name@version`), with the same release's GitHub tag kept
  as the registry-unreachable fallback. The setup catalog carries both.

## `plugins.json`

```json
{
  "plugins": {
    "dsh-telegram-connector": {
      "spec": "dsh-telegram-connector@0.13.1",
      "fallback": "github:vladtsvirko/dsh-telegram-connector#v0.13.1",
      "minimum": "0.13.1",
      "repository": "vladtsvirko/dsh-telegram-connector"
    },
    "dsh-penpot-plugin": {
      "spec": "dsh-penpot-plugin@0.3.1",
      "fallback": "github:vladtsvirko/dsh-penpot-plugin#v0.3.1",
      "minimum": "0.3.1",
      "repository": "vladtsvirko/dsh-penpot-plugin"
    }
  }
}
```

- `spec` is the exact npm package a fresh install or repair installs.
- `fallback` is the same release as a GitHub tag, used only when the registry
  cannot be reached. It never moves to a different version.
- `minimum` is the floor a boot enforces. An installed version at or above it
  is left alone, even when it is newer than `spec`.
- A setup release raises `minimum` only when it genuinely needs newer plugin
  behaviour. Bumping `spec` alone does not downgrade an existing deployment.
- An explicit `.env` override (`DSH_TELEGRAM_PLUGIN` / `PENPOT_PLUGIN_REF`) is
  honoured, except when it points below `minimum`: the catalog spec wins and the
  boot warns. A stale pin cannot keep a deployment on an unsupported plugin.

## How updates move

| Mechanism | Moves | Rollback |
|---|---|---|
| `/system update setup` | setup checkout + installed DSH; the entrypoint then applies the plugin floor | automatic on failed health; one previous checkout + profile snapshot |
| `/system update connector` | connector to the newest compatible npm version, or `to <version>`; a GitHub-installed connector uses its repo tags | supervisor trial: Commit / Roll back / deadline; failed install restores at once |
| `/system update penpot` | Penpot plugin through the plugin manager | trial opened before removal; failed install re-adds the previous spec, otherwise supervisor rollback |
| `/system update plugin <name>` | any npm- or GitHub-installed bundle | same as Penpot |
| `/system restart` | nothing (restarts current state) | trial |
| `/system rollback` | profile only | does not move the setup checkout or DSH |
| host `./update.sh --apply` | same as setup update | same health gate |

Plugin updates and setup updates are independent. A setup release no longer
forces a connector version, and a connector release no longer needs a setup
release. The only coupling left is `minimum`: a setup release can say "this
deployment needs at least connector X", and the next boot enforces that floor.

## What may jump

| From → to | Allowed by default? | How |
|---|---|---|
| same setup DSH part, same product major | yes | `/system update setup` |
| same product major, different DSH part | no | `--i-know-versions-are-incompatible` |
| different setup product major | no | the same flag |
| same setup version | no-op | the updater reports no target |
| older setup tag | no | rollback is separate |
| any newer plugin version whose DSH range matches | yes | `/system update connector` / `penpot` / `plugin` |
| plugin version whose DSH range does not match | no | update DSH first, or install on the host with an explicit exemption |

Compatible setup releases may be **skipped**: `0.1.1 → 0.4.2` is allowed when the
DSH part and the product major match. Tags on side branches are skipped because
the target must be a descendant of the running tag. Ordering is release-aware
(`versionsort.suffix=-rc`).

## Scopes

| Mechanism | Changes | Rollback |
|---|---|---|
| `/system restart`, `/system update connector`, plugin mutations | **profile** (`data/home/profiles/web`) | supervisor snapshot; Commit / Roll back / deadline |
| `/system update setup` | setup checkout, installed DSH, profile state snapshot | automatic on failed health gate |
| `/system rollback` | profile only | does not move the checkout or the setup tag |

## Release checklists

### Setup

1. Align the DSH part in `VERSION` to the tested DSH release; reset the product
   to `0.0.0` for a new DSH line. Bump the product for setup changes.
2. Update `VERSION`, the `AGENTS.md` example, README compatibility notes,
   `docs/VERSIONS.md` and any doc that names the current tag.
3. If the release needs newer plugin behaviour, bump that plugin's `minimum` in
   `plugins.json` (and its `spec`/`fallback`). The version must already exist on
   npm.
4. Run `node --test *.test.mjs`, `bash -n update.sh install.sh entrypoint.sh
   healthcheck.sh scripts/repair.sh`, `node scripts/check-version.mjs` with
   `GITHUB_REF_NAME=v<VERSION>`, and `node scripts/plugin-preflight.mjs`
   (`--remote` after the npm versions are published and the tags are pushed).
5. Commit, tag and push the setup. CI validates the tag; it does not look for a
   connector tag.

### Connector

1. Update `package.json`/`package-lock.json`, `COMPATIBILITY.md` (tested DSH
   row), `CHANGELOG.md` and the README install pin.
2. Run `npm run typecheck && npm test && npm run build` and
   `npm publish --dry-run`.
3. Commit, tag `v<version>`, push. The tag runs `.github/workflows/publish.yml`,
   authenticated by npm Trusted Publishing (OIDC), and publishes exactly that
   version. The first version of a new package is published manually once,
   before its trusted publisher exists.
4. After the npm version exists, raise the setup's `spec`/`fallback`/`minimum`
   and run `scripts/plugin-preflight.mjs --remote`.

### Penpot plugin

1. Update `package.json`/`package-lock.json`, `COMPATIBILITY.md` (tested DSH and
   Penpot rows), `CHANGELOG.md` and the README install pin.
2. Run `npm run typecheck && npm test && npm run build` and
   `npm publish --dry-run`.
3. Commit, tag `v<version>`, push. The same publish workflow uploads it.
4. Optionally raise the setup's recommendation.

Do not move or reuse a tag. Do not tag only one repository when a release is
meant to move both tracks.
