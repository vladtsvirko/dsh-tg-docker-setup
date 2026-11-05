# Release and version rules

The setup repo ships one aligned release together with DSH and the connector:

```
VERSION:      0.2.1-rc.5-0.12.10
git tag:      v0.2.1-rc.5-0.12.10
```

- The DSH part is the runtime the release installs. It is the prefix of
  `VERSION`; `install.sh` installs `@deepseek-ai/dsh@<DSH part>`. There is no
  image and no `.env` DSH pin.
- The product part starts at `0.0.0` for each new DSH alignment; patch = fix,
  minor = compatible feature, **major = breaking**. `0.x` is the compatible
  line; never ship a breaking change as `0.x`. The compatibility promise covers
  commands, configuration and data, not the deployment shape: while the project
  is pre-1.0 and single-operator, dropping a deployment mode is a minor, and the
  CHANGELOG says so in the first paragraph.
- Same product major **and the same DSH part**: updates may jump between
  releases.
- Different product major **or a different DSH part**: only with the explicit
  `--i-know-versions-are-incompatible` flag. Both `/system update setup` and
  `update.sh --apply` accept it; neither crosses without it.
- Tags are immutable. `VERSION`, the tag, the `AGENTS.md` example and the
  connector tag move together.
- Every setup release needs a **matching connector tag**, including a setup-only
  fix. The entrypoint installs `github:vladtsvirko/dsh-telegram-connector#v${DSH_SETUP_VERSION}`;
  a setup tag without a connector tag leaves the bot uninstalled.

## Release checklist

1. Align the DSH part in `VERSION` to the tested DSH release; reset the product
   part to `0.0.0` when the DSH part changes. Bump the product for setup changes.
2. Update `VERSION`, the `AGENTS.md` example, README compatibility notes,
   `docs/VERSIONS.md` and any doc that names the current tag
   (`docs/UAT.md`, `docs/SELF-UPDATE.md`).
3. Run `node --test *.test.mjs`, `bash -n update.sh install.sh entrypoint.sh
   healthcheck.sh scripts/repair.sh`, and
   `node scripts/check-version.mjs` with `GITHUB_REF_NAME=v<VERSION>`.
4. Commit and tag the matching **connector** release first; the setup's
   entrypoint resolves that tag on the next boot.
5. Commit, tag and push the setup. CI runs `scripts/check-version.mjs` and, on a
   tag build, proves the matching connector tag exists with `git ls-remote`. It
   does not compare the connector's `package.json`; the connector's own CI checks
   its half, so the version *values* still have to be kept in step by this
   checklist.

`/system update setup` is the normal no-SSH path: it drains agents, then the
`updater` service runs `update.sh --to <target>`, which checks out,
installs and restarts the service, and rolls back on a failed health gate. The
host `./update.sh --apply` path remains for bootstrap, break-glass, or a
deliberate manual update. The runtime has no privileged access; the updater is
the only component that restarts it.
