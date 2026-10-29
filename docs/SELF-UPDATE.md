# Setup updates, one tag at a time

`update.sh --self` moves the **setup checkout** (compose, Dockerfile, entrypoint,
supervisor, docs) to the **latest compatible release tag**. It does not pull
`main`.

```sh
./update.sh --self-check   # fetch tags, show the target and its commits; change nothing
./update.sh --self         # latest compatible tag, build, health gate, rollback
./update.sh --self --i-know-versions-are-incompatible   # allow a major/DSH jump
```

`--self-check` exits `0` when there is no newer compatible tag, `2` when there is,
and `1` on an error. `--self` asks for confirmation unless `ASSUME_YES=1`.

## Tag convention

Tags match `<dsh>-<major>.<minor>.<patch>`, for example
`v0.2.1-rc.2-0.1.0`, and must be ancestors of the current one:

```sh
git tag -a v0.2.1-rc.2-0.1.0 -m "setup 0.2.1-rc.2-0.1.0"
git push origin v0.2.1-rc.2-0.1.0
```

- Product `0.x` is the compatible line; `1.0.0` marks a break.
- The product part resets to `0.0.0` for each new DSH alignment.
- Same product major **and same DSH part** may jump: `0.0.1 → 0.4.2`.
- Crossing a major **or** a DSH line needs
  `--i-know-versions-are-incompatible`; `/system update all` never crosses.

The checkout must be **on a tag**, not on `main`:

```sh
git describe --tags --exact-match   # must print a tag
```

Ordering is release-aware (`versionsort.suffix=-rc`); a tag on a side branch is
skipped because it is not a descendant of the current one.

## What `--self` does

1. Refuses a dirty tree, fetches tags, resolves **current tag** and the latest
   **compatible target** (`current_tag`, `newer_tags`, `target_tag`).
2. Shows the commits between them; asks for confirmation.
3. Tags the running image as `dsh-backend:self-previous`.
4. Optionally backs up `data/home` (`NO_BACKUP=1` skips).
5. Checks out the target tag (detached HEAD), builds, and starts with a health gate:
   `docker compose up -d --wait --wait-timeout $HEALTH_TIMEOUT` (falls back to
   polling when Compose is older).
6. Runs the usual `verify` checks (web answers, recent plugin warnings).
7. On build/health failure: restores the previous tag checkout, retags
   `self-previous` as the running image, starts it, and verifies the rollback.

## Limits

- One rollback image (`dsh-backend:self-previous`), not a history. Tag more copies
  yourself if you need depth.
- Data migrations are not rolled back. `data/home` is backed up before the update;
  restore it if the old image cannot read the new state.
- No systemd and no Docker socket in the runtime: run `--self` from the host. A
  future Telegram trigger would write a request flag; a separate privileged
  updater would run this same script.
- `--self` updates the setup repo and the DSH version it contains; there is no
  separate DSH-version updater any more.
