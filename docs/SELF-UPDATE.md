# Setup updates, one tag at a time

There are two entry points to the same updater:

- **`/system update all`** in the bot control chat — normal operation, no host
  shell. The connector drains all agents, asks the updater sidecar, and reports
  the result to Telegram. See [`UPDATER.md`](UPDATER.md).
- **`./update.sh --self`** on the host — bootstrap, break-glass, or a deliberate
  manual update. It does not require the connector to be healthy.

Both move the **setup checkout** (compose, Dockerfile, entrypoint, supervisor,
docs) to a release tag. Neither pulls `main`.

```sh
./update.sh --self-check   # fetch tags, show the target and its commits; change nothing
./update.sh --self         # latest compatible tag, build, health gate, rollback
./update.sh --self --i-know-versions-are-incompatible   # allow a major/DSH jump
./update.sh --self-to v0.2.1-rc.2-0.1.12                # exact target, used by the updater
```

`--self-check` exits `0` when there is no newer compatible tag, `2` when there is,
and `1` on an error. `--self` asks for confirmation unless `ASSUME_YES=1`.
`--self-to` requires the target to be a newer aligned tag and a descendant of the
running one.

## Tag convention

Tags match `<dsh>-<major>.<minor>.<patch>`, for example
`v0.2.1-rc.2-0.1.12`, and the target must be a descendant of the current one:

```sh
git tag v0.2.1-rc.2-0.1.12
git push origin v0.2.1-rc.2-0.1.12
```

- Product `0.x` is the compatible line; `1.0.0` marks a break.
- The product part resets to `0.0.0` for each new DSH alignment.
- Same product major **and same DSH part** may jump: `0.1.1 → 0.4.2`.
- Crossing a major **or** a DSH line needs
  `--i-know-versions-are-incompatible`; `/system update all` accepts the same
  explicit flag, but never crosses without it.
- The setup release and the connector release carry the same tag. The entrypoint
  installs the connector tag derived from the setup `VERSION`; see
  [`VERSIONS.md`](VERSIONS.md).

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
4. Checks out the target tag (detached HEAD) and builds while the old container is
   still running.
5. Stops `dsh` to freeze state, snapshots `data/home` + `data/supervisor`
   (`snapshot_state`; `data/workspace` is never included), starts the new image,
   and waits for the health gate:
   `docker compose up -d --wait --wait-timeout $HEALTH_TIMEOUT` (falls back to
   polling when Compose is older). The gate also requires the **published** web
   port to answer from the host, not just the container healthcheck.
6. Runs the usual `verify` checks (web answers, recent plugin warnings).
7. On build/health failure: restores the snapshot, restores the previous tag
   checkout, retags `self-previous` as the running image, starts it, and verifies
   the rollback. Rollback does not require the published web port, so Telegram
   can come back even if the new web bind is broken.

## Limits

- One rollback image (`dsh-backend:self-previous`), not a history. Tag more copies
  yourself if you need depth.
- One `backups/self-*.tgz` snapshot (home + supervisor). Data migrations are not
  undone by an image rollback; restore the snapshot if the old image cannot read
  the new state.
- `data/workspace` is never snapshotted or restored. Changes a failed deployment
  made there are not undone, and files written there after the snapshot survive a
  rollback.
- `/system update all` has no timeout or cancel after acceptance; a stuck session
  blocks it. `/system rollback` is a profile rollback, not an image rollback.
- No systemd and no Docker socket in the runtime: host `--self` still needs a
  shell. The normal path is the updater sidecar, which has the socket and is
  reachable only from the connector. See [`LIMITS.md`](LIMITS.md).
- The updater image itself is not rebuilt by `--self`; only the `dsh` service is.
  A change to `updater.Dockerfile` still needs a host `docker compose build`.
- A crash of the updater mid-apply is not automatically resumed. The result file,
  checkout, images and container state are the recovery inputs.
