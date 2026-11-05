# Release and version rules

Three artifacts, two release tracks. The setup is released as one unit with
DSH; each plugin is released on its own and pinned by the setup's `plugins.json`.

```
setup VERSION:  0.2.1-rc.5-0.13.0        tag v0.2.1-rc.5-0.13.0
connector:      0.13.0                    tag v0.13.0
penpot plugin:  0.3.0                     tag v0.3.0
```

- The DSH part is the runtime the setup release installs. It is the prefix of
  `VERSION`; `install.sh` installs `@deepseek-ai/dsh@<DSH part>`. There is no
  image and no `.env` DSH pin.
- The setup product part starts at `0.0.0` for each new DSH alignment; patch =
  fix, minor = compatible feature, **major = breaking**. `0.x` is the compatible
  line; never ship a breaking change as `0.x`. The compatibility promise covers
  commands, configuration and data, not the deployment shape: while the project
  is pre-1.0 and single-operator, dropping a deployment mode is a minor, and the
  CHANGELOG says so in the first paragraph.
- Same product major **and the same DSH part**: updates may jump between setup
  releases.
- Different product major **or a different DSH part**: only with the explicit
  `--i-know-versions-are-incompatible` flag. Both `/system update setup` and
  `update.sh --apply` accept it; neither crosses without it.
- Tags are immutable. `VERSION`, the tag and the `AGENTS.md` example move
  together.
- **Plugins are independent.** `plugins.json` pins a recommended `ref` and a
  `minimum` for the connector and the Penpot plugin. A fresh install and a
  repair use the ref; a boot only forces a reinstall when the installed version
  is below the minimum. A newer compatible tag installed from the bot stays
  installed. A setup release does **not** need a matching connector or plugin
  tag, and a plugin release does **not** need a setup release.
- The setup never derives a plugin spec from `VERSION`. A setup release that
  needs a newer plugin raises `minimum`; that is the only coupling left.

## Release checklist

1. Align the DSH part in `VERSION` to the tested DSH release; reset the product
   part to `0.0.0` when the DSH part changes. Bump the product for setup changes.
2. Update `VERSION`, the `AGENTS.md` example, README compatibility notes,
   `docs/VERSIONS.md` and any doc that names the current tag
   (`docs/UAT.md`, `docs/SELF-UPDATE.md`).
3. If the release depends on newer plugin behaviour, bump the plugin's `minimum`
   in `plugins.json` (and usually its `ref`). Do not add a matching plugin tag
   requirement to CI.
4. Run `node --test *.test.mjs`, `bash -n update.sh install.sh entrypoint.sh
   healthcheck.sh scripts/repair.sh`, and
   `node scripts/check-version.mjs` with `GITHUB_REF_NAME=v<VERSION>`.
   `node scripts/plugin-preflight.mjs` checks the sibling versions against
   `plugins.json`; after tagging the plugins, `--remote` proves the tags exist.
5. Commit, tag and push the setup. CI runs `scripts/check-version.mjs`; it does
   not look for a connector tag.

The connector and Penpot plugin have their own `AGENTS.md` and release
checklists. Tag them first only when the setup's `minimum` requires that tag; a
plugin release alone is picked up by `/system update connector` and
`/system update penpot`.

`/system update setup` is the normal no-SSH path: it drains agents, then the
`updater` service runs `update.sh --to <target>`, which checks out,
installs and restarts the service, and rolls back on a failed health gate. The
host `./update.sh --apply` path remains for bootstrap, break-glass, or a
deliberate manual update. The runtime has no privileged access; the updater is
the only component that restarts it.
