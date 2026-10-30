# Versions and update policy

Two repositories ship one release:

| Artifact | Repository | What it contains |
|---|---|---|
| connector | `dsh-telegram-connector` | The Cordis plugin installed into the DSH profile |
| setup | `dsh-tg-docker-setup` | Compose file, Dockerfile, entrypoint, supervisor, updater, host scripts |

They always carry the **same tag and version**. A release is the pair, not one
repository.

## Scheme

```
<dsh-version>-<major>.<minor>.<patch>          tag: v<same>
v0.2.1-rc.2-0.1.13
```

- **DSH part** (`0.2.1-rc.2`) is the exact DSH release the pair was built and
  tested against. Prerelease suffixes are part of the version.
- **Product part** (`0.1.13`) is ours.
  - It resets to `0.0.0` when the pair aligns to a new DSH line.
  - `0.x` is the compatible line. A patch is a fix, a minor is a compatible
    feature, and `1.0.0` (or any new major) marks an incompatible change.
  - Never ship a breaking change in the `0.x` line.
- Tags are immutable. Do not move, delete, or reuse a released tag.
- The tag, connector `package.json`, setup `VERSION`, the image tags and the
  Dockerfile build args must agree; CI checks this on the tag.

## Why the versions are coupled

The setup image does not float the connector. `entrypoint.sh` derives

```
DSH_TELEGRAM_PLUGIN=github:vladtsvirko/dsh-telegram-connector#v${DSH_SETUP_VERSION}
```

and forces that ref even when `.env` contains an older override pointing at the
official connector. (A ref for a different connector is left alone.) When the ref
recorded in `.telegram-plugin-ref` changes, it reinstalls the connector before
the runtime starts.

Consequences:

- A setup version bump **requires a connector tag with the same version**. A
  setup-only fix still cuts a connector maintenance tag; otherwise the entrypoint
  asks for a tag that does not exist.
- A connector change you want a running setup to use **requires a setup release**
  with the same version. A connector tag alone is not picked up by a reboot: the
  boot pin remains the old setup tag.
- `/system update connector` reinstalls the **pinned** connector. It repairs or
  reapplies that version; it does not choose a newer connector tag.
- `/system update all` moves the setup tag, rebuilds the image, and the new
  entrypoint installs the connector tag derived from it.

The `.env` variable `DSH_TELEGRAM_PLUGIN` exists for alternative connectors. The
official connector ref is always rewritten to the setup tag.

There is no `DSH_VERSION` environment knob any more. DSH is hardcoded in the
setup release (`ARG DSH_VERSION` and the image tag).

## What may jump

| From → to | Allowed by default? | How |
|---|---|---|
| same DSH part, same product major | yes | `/system update all` (mode `compatible`) |
| same product major, different DSH part | no | `/system update all --i-know-versions-are-incompatible` or host `./update.sh --self --i-know-versions-are-incompatible` |
| different product major | no | same explicit flag |
| same version | no-op | updater reports no target |
| older tag | no | the updater rejects it; rollback is a separate, automatic path |

Compatible releases may be **skipped**: `0.1.1 → 0.4.2` is allowed when the DSH
part and the product major match. Tags on side branches are skipped because the
target must be a descendant of the running tag. Ordering is release-aware
(`versionsort.suffix=-rc`).

`/system` never crosses a DSH line or a product major on its own. The flag is an
explicit human decision, accepted only from an allowlisted user in the control
chat. `/system status` and the update card show the target before acceptance.

## Scopes

| Mechanism | Changes | Rollback |
|---|---|---|
| `/system restart`, `/system update connector`, plugins | **profile** (`data/home/profiles/web`) | supervisor snapshot; Commit / Roll back / deadline |
| `/system update all` | setup checkout, DSH image, connector pin, profile state snapshot | automatic on failed health gate; one previous image + one `self-*.tgz` |
| host `./update.sh --self` | same as `/system update all`, without draining agents | same |
| `/system rollback` | profile only | does **not** move the image or the setup tag |

The image updater only moves forward. There is no Telegram command that says
"run the previous image"; a failed update restores it automatically, and a manual
image rollback is a host operation (`dsh-backend:self-previous`).

## Release checklist

1. Bump the connector product version when the connector changes. For a
   setup-only fix, still cut a connector **maintenance** release with no code
   change.
2. Update connector `package.json` / `package-lock.json`, `COMPATIBILITY.md` and
   `CHANGELOG.md`.
3. Run `npm run typecheck && npm test && npm run build` in the connector.
4. Commit and tag the **connector first**; the setup image must be able to
   resolve `v<version>` while it builds.
5. Bump setup `VERSION`, all `image:` tags, `Dockerfile`'s `DSH_SETUP_VERSION`
   (and `DSH_VERSION` only on a real DSH alignment), and the version examples in
   `AGENTS.md`.
6. Run `node --test supervisor.test.mjs git-credentials.test.mjs`, `bash -n` on
   the shell entrypoints and `docker compose config`.
7. Commit and tag the setup. Both CI version checks must pass.

Do not tag only one repository. Do not tag a commit that is not on `main`.
