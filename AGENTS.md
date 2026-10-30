# Release and version rules

The setup repo ships one aligned release together with DSH and the connector:

```
VERSION:      0.2.1-rc.2-0.1.14
git tag:      v0.2.1-rc.2-0.1.14
image:        dsh-backend:0.2.1-rc.2-0.1.14
Dockerfile:   ARG DSH_VERSION=0.2.1-rc.2
```

- The DSH part is the runtime the image installs; it is hardcoded in the image
  tag and Dockerfile, never read from `.env`.
- The product part starts at `0.0.0` for each new DSH alignment; patch = fix,
  minor = compatible feature, **major = breaking**. `0.x` is the compatible
  line; never ship a breaking change as `0.x`.
- Same product major **and the same DSH part**: updates may jump between
  releases.
- Different product major **or a different DSH part**: only with the explicit
  `--i-know-versions-are-incompatible` flag. Both `/system update all` and
  `update.sh --self` accept it; neither crosses without it.
- Tags are immutable. `VERSION`, the tag, every image tag, `Dockerfile`
  `DSH_SETUP_VERSION` and the connector tag move together.
- Every setup release needs a **matching connector tag**, including a setup-only
  fix. The entrypoint installs `github:vladtsvirko/dsh-telegram-connector#v${DSH_SETUP_VERSION}`;
  a setup tag without a connector tag leaves the bot uninstalled.

## Release checklist

1. Align the hardcoded DSH version (Dockerfile arg + image tag) to the tested
   DSH release; reset the product part to `0.0.0`. Bump the product for
   setup/connector changes.
2. Update `VERSION`, every image tag, `Dockerfile`, the AGENTS version example,
   README compatibility notes and `docs/SELF-UPDATE.md` / `docs/VERSIONS.md` if
   semantics changed. There is no `.env.example` connector pin: the official ref
   is derived.
3. Run `node --test supervisor.test.mjs git-credentials.test.mjs`,
   `bash -n update.sh entrypoint.sh healthcheck.sh` and `docker compose config`
   (the service requires a `.env`; use a throwaway checkout with
   `cp .env.example .env`, never overwrite a deployed one).
4. Commit and tag the matching **connector** release first; the setup image must
   resolve that tag while it builds.
5. Commit, tag and push the setup. CI runs `scripts/check-version.mjs`; both
   repositories' tags must agree.

`/system update all` is the normal no-SSH path: it drains agents, then the
`updater` sidecar runs `update.sh --self-to <target>`, which rebuilds and starts
the image and rolls back on a failed health gate. The host `./update.sh --self`
path remains for bootstrap, break-glass, or a deliberate manual update. The bot
container still has no Docker socket; the updater is the only privileged
component.
