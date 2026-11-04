# Setup updates, one tag at a time

There are two entry points to the same update path:

- **`/system update all`** in the bot control chat — normal operation, no host
  shell. The connector drains all agents, asks the updater service, and reports
  the result to Telegram. See [`UPDATER.md`](UPDATER.md).
- **`./update.sh --self`** on the host — bootstrap, break-glass, or a deliberate
  manual update. It does not require the connector to be healthy.

Both move the **setup checkout** (installer, entrypoint, supervisor, updater,
docs) to a release tag, install the matching DSH, and restart `dsh.service`.
Neither pulls `main`.

```sh
./update.sh --self-check   # fetch tags, show the target and its commits; change nothing
sudo ./update.sh --self    # latest compatible tag, install, health gate, rollback
sudo ./update.sh --self --i-know-versions-are-incompatible   # allow a major/DSH jump
sudo ./update.sh --self-to <newer tag>                        # exact target, used by the updater
```

`--self-check` exits `0` when there is no newer tag at all, `2` when a newer tag
exists (compatible or only incompatible — it prints which), and `1` on an error.
`--self` asks for confirmation unless `ASSUME_YES=1`. Run it as root
(`sudo ./update.sh --self`): it writes the root-owned checkout, installs DSH
globally and restarts the unit.

Every successful update ends with the same health check an install runs
(`scripts/repair.sh --fix`, exposed as `./update.sh --doctor`). It catches the
files an update rewrites — `.env`, the profile patch, the stored credential —
so a half-applied change is repaired before the next boot instead of surfacing
as a model call that fails for no visible reason.
`--self-to` requires the target to be a newer aligned tag and a descendant of the
running one, and it enforces the same compatibility rule as `--self`: crossing a
DSH line or a product major needs `--i-know-versions-are-incompatible`. The
updater passes that flag only after its own `/update` check accepted the
crossing, so an unattended update cannot cross on its own.

## Tag convention

Tags match `<dsh>-<major>.<minor>.<patch>`, for example
`v0.2.1-rc.5-0.8.1`, and the target must be a descendant of the current one:

```sh
git tag v0.2.1-rc.5-0.8.1
git push origin v0.2.1-rc.5-0.8.1
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
3. Snapshots `data/home` + `data/supervisor` to `backups/self-<stamp>.tgz`
   (`data/workspace` is never included) and keeps one snapshot.
4. Checks out the target tag (detached HEAD). The old runtime keeps running.
5. Writes `DSH_SETUP_VERSION` into `.env` and installs
   `@deepseek-ai/dsh@<DSH part>` globally when the installed version differs.
6. Runs the entrypoint's prepare step as the service user, which installs the
   connector tag derived from the new version.
7. Restarts `dsh.service`, then waits for the health gate: the unit active **and**
   the web port answering.
8. Runs the usual `verify` checks (web answers, recent plugin warnings) and the
   doctor (`scripts/repair.sh --fix`).
9. On a health-gate failure: restores the snapshot, checks the previous tag
   out, rewrites `DSH_SETUP_VERSION`, restarts, and verifies the rollback. If
   the rollback fails too, the snapshot path is printed for recovery.

The previous release is a tag plus the data snapshot.

## Limits

- One `backups/self-*.tgz` snapshot (home + supervisor), not a history. Data
  migrations are not undone by a tag rollback; restore the snapshot if the old
  runtime cannot read the new state.
- `data/workspace` is never snapshotted or restored. Changes a failed deployment
  made there are not undone, and files written there after the snapshot survive a
  rollback.
- `/system update all` has a job deadline: the updater stops a job that runs
  longer than `DSH_UPDATE_TIMEOUT_SECONDS` (default 30 minutes) with `SIGTERM`,
  then `SIGKILL` after ten seconds, and `/system cancel` stops a running job.
  The card's **✖ Cancel** button exists only while it is still draining. A stuck
  session blocks the drain, not the apply. `/system rollback` is a profile
  rollback, not a setup-tag rollback.
- A host `--self` needs a root shell. The normal path is the updater service,
  which reaches `127.0.0.1:8787` with the token from `.env`. See
  [`LIMITS.md`](LIMITS.md).
- The updater's code is the checkout it runs. A setup update changes that code
  on its next start; a change to the updater's **unit** needs
  `sudo ./install.sh --yes`.
- A crash of the updater mid-apply is not automatically resumed. The result
  file, checkout and snapshot are the recovery inputs.
