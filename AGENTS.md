# Release and version rules

The setup repo ships one aligned release together with DSH and the connector:

```
VERSION:      0.2.1-rc.2-0.1.3
git tag:      v0.2.1-rc.2-0.1.3
image:        dsh-backend:0.2.1-rc.2-0.1.3
Dockerfile:   ARG DSH_VERSION=0.2.1-rc.2
```

- The DSH part is the runtime the image installs; it is hardcoded in the image
  tag and Dockerfile, never read from `.env`.
- The product part starts at `0.0.0` for each new DSH alignment; patch = fix,
  minor = compatible feature, **major = breaking**. `0.x` is the compatible
  line; never ship a breaking change as `0.x`.
- Same product major: updates may jump between releases.
- Different product major **or a different DSH part**: only with
  `--i-know-versions-are-incompatible` in `update.sh --self`. `/system update all`
  never crosses automatically.
- Tags are immutable. `VERSION`, the tag and the connector pin move together.

## Release checklist

1. Align the hardcoded DSH version (Dockerfile arg + image tag) to the tested
   DSH release; reset the product part to `0.0.0`. Bump the product for
   setup/connector changes.
2. Update `VERSION`, the image tags, `Dockerfile`, `.env.example` connector pin,
   README compatibility notes and `docs/SELF-UPDATE.md` if semantics changed.
3. Run `node --test supervisor.test.mjs git-credentials.test.mjs`,
   `bash -n …` and `docker compose config`.
4. Commit, tag `v<version>`, push. CI runs `scripts/check-version.mjs`.
5. Create the matching connector tag first; the pin must resolve when the image
   installs the connector.

`/system update all` is a **check** only: the container cannot rebuild its own
image. It reports the host command (`./update.sh --self-check`); applying the
setup update stays on the host, with no systemd and no Docker socket in the bot.
