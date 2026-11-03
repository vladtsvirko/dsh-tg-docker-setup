# Changelog

The setup repo ships in lockstep with `dsh-telegram-connector`: `VERSION` is the
tag, the image tag and the connector tag at once. Connector-side changes are in
that repository's changelog; this file records what the installer, the
supervisor, the updater and the entrypoint changed.

Earlier releases are the git tags; this file starts at `0.2.1-rc.2-0.6.0`.

## 0.2.1-rc.5-0.1.1

### Fixed

- **The sudo re-run asked the mode twice and looped.** The root check sat after
  the mode question, so the answer was lost across the re-exec: it asked again,
  and on a piped stdin every further answer went to a question that had already
  been answered — the install appeared to hang. It now runs *before* any
  question, so nothing is asked twice.
- **`sudo -E` is not portable.** Ubuntu's default sudoers answers "preserving the
  entire environment is not supported, '-E' is ignored", which also dropped the
  answers given as environment variables. The re-run passes them explicitly
  (`sudo env DSH_… bash install.sh`) and attaches stdin to the terminal, so the
  prompts keep working when the script arrived through a pipe.
- **The bootstrap called apt with no packages.** \`==> installing\` with an empty
  list, and an `apt-get install ""` behind it, whenever git and curl were already
  present. It now skips apt entirely in that case.
- Prompts are written to stderr, so they survive a redirected stdout.

## 0.2.1-rc.5-0.1.0

### Added

- **One file installs everything.** `wget -qO- …/install.sh | bash` (or `curl`)
  fetches the newest release into a checkout, then installs it — no `git clone`,
  no manual prerequisites:

  ```sh
  wget -qO- https://raw.githubusercontent.com/vladtsvirko/dsh-tg-docker-setup/main/install.sh | bash
  ```

  The checkout matters: it is what `/system update all` moves between releases
  later. `--ref` pins the tag, `--dir` chooses where it lands
  (`/opt/dsh-setup` as root, `~/dsh-setup` otherwise).
- **Docker is installed when it is missing.** Docker mode installs
  `docker.io` + `docker-compose-v2` from the distro, starts the daemon, and adds
  the invoking user to the `docker` group; if the distro has no usable packages
  (Debian 12, Ubuntu with `universe` off) it falls back to Docker's own apt
  repository. Native mode installs Node 22 from NodeSource instead. The plan
  says which of the two will happen, and `--no-deps` keeps the installer away
  from apt entirely.
- **The questions are asked once.** An install that needs root re-executes itself
  under `sudo` before the first question, for both modes, instead of asking
  everything and then failing on the socket or the systemd unit.
- **`--check` from a lone file shows the whole plan**, not just the bootstrap:
  it fetches a temporary checkout, prints the real plan against the directory
  you asked for, and leaves nothing behind.
- **One confirmation before anything changes**: `Proceed? [Y/n]` after the plan.

### Fixed

- **Prompts work when the script arrives through a pipe.** `read` used to take
  the next line of the script itself, so every question silently took its
  default; prompts now read `/dev/tty` when stdin is not a terminal, and are
  skipped (with the documented defaults) when there is no terminal at all.
- **`[ -r /dev/tty ]` is not a terminal test.** Existence is not use: opening it
  is, which is what CI and cron need to avoid hanging.

### Notes

- `docs/UAT.md` installs with the one-liner in both modes, because that is the
  path a stranger takes.
## 0.2.1-rc.5-0.0.0

Alignment release against DSH `0.2.1-rc.5` (from `0.2.1-rc.2`). The product
part restarts at `0.0.0` for the new DSH line; no setup code changed.

### Changed

- `Dockerfile` pins `DSH_VERSION=0.2.1-rc.5`; `VERSION`, the image tags, the
  AGENTS example and the native installer's `DSH_PKG` default follow.
- The connector is rebuilt against rc.5 and re-tagged; the setup image installs
  that tag through the usual derived ref.

### Added

- `docs/UPSTREAM-WATCH.md` — the daily check for a new DSH release candidate
  (npm `dist-tags` → release notes → tree diff → contract-package byte compare),
  with the per-release plans it produces in `docs/upgrades/`.
- `docs/upgrades/0.2.1-rc.5.md` — the first plan, including the rc.2 → rc.5
  compatibility findings (no contract change; 24 of 294 shipped packages differ).

### Notes

- The model picker follows provider credentials: a route without a usable key is
  hidden, and the `deepseek-official` route follows DeepSeek's published model
  list. Only models the deployment can actually call are offered.

## 0.2.1-rc.2-0.8.0

### Fixed

- **A cross-line update needs the flag on every path.** The updater accepted
  `mode: available` from anyone holding the token and would jump a DSH line or a
  product major without `--i-know-versions-are-incompatible`, which both
  `/system` and `update.sh` require. The request now has to carry
  `"incompatible": true`, and `/target` reports whether a move would cross.
- **`/trial/arm` and `/trial/abandon` respect a running operation**, so a restart
  or a rollback cannot be armed underneath.
- **The rollback point is swapped, not deleted first.** `snapshotStable` removed
  the old snapshot before renaming the new one into place; a crash between the
  two left no rollback point at all.
- **`check-version.mjs` matches whole values.** `includes('image: dsh-backend:0.7.4')`
  also matches `…:0.7.40`, so a release could pass with the wrong image tag.

### Notes

- The connector now sends `incompatible: true` with `mode: available`, which is
  what `/system update all --i-know-versions-are-incompatible` means.

## 0.2.1-rc.2-0.7.4

### Fixed

- **The native smoke job installed a ref its deployment repository did not
  have.** `install.sh` initialises its own git repository and fetches tags, so
  `--ref HEAD` (a commit from the workflow checkout) was never there; the run
  now installs the release tag the workflow was triggered by, and on a branch run
  the latest tag. The PR trigger is gone: a branch ref cannot be installed.

## 0.2.1-rc.2-0.7.3

### Fixed

- **The native smoke job tested the wrong code.** It installed the previous
  release and updated to the new one — but an update is driven by the *installed*
  release, so the 0.7.0 → 0.7.1 → 0.7.2 runs kept executing the older, broken
  update path and failed for that reason alone. The job now installs the release
  it is testing and runs `update.sh --plugin` from the deployment directory,
  which is the same prepare → restart → health path an update takes.

  The three failed runs did their job, though: the 0.7.1 failure was the
  `run_as_service` working directory, fixed in 0.7.2.

## 0.2.1-rc.2-0.7.2

### Fixed

- **Native prepare ran from the wrong directory.** `run_as_service` inherited
  the caller's cwd, so `cd /srv/dsh && ./update.sh --self` — the way the header
  says to run it — invoked `dsh plugin add` in the directory that holds `.env`.
  `dsh` loads the `.env` of its working directory and refuses launch-only keys
  there (`DSH_BIND_IP … export it instead`), so every native update failed to
  prepare and rolled back. It now runs from `data/workspace`, exactly as the
  systemd unit does, with a test that asserts the directory.
- The native smoke workflow prints the update log and the journal when its update
  step fails, instead of only "step failed".

## 0.2.1-rc.2-0.7.1

### Fixed

- **The native smoke workflow had two bugs of its own**, which is why its 0.7.0
  run failed on the first real tag: it probed the runtime on the default port
  4310 while the CI answers pin 4311, and it ran `update.sh` from the checkout
  instead of the deployment directory (where `.env` and `VERSION` live). Both are
  fixed; the tag exists so the released workflow is one that runs green.

## 0.2.1-rc.2-0.7.0

### Added

- **`install.sh` asks who the admin is.** `DSH_ADMIN_USER_ID` is written to
  `.env` (it defaults to the first allowed id) and the plan shows it. Access and
  administration are now separate: one account may update, restart, roll back or
  change plugins.
- **`docs/UPGRADE.md`**: what an upgrade touches, compatible vs crossing, the
  trial and how to confirm or roll it back, a rollback drill you can run while
  nothing is at stake, the recovery table for every stranded state, and the
  upgrade path from 0.4.x.
- **`docs/UAT.md`**: the acceptance run for both modes, with the exact commands
  and the expected output per step.
- **`SECURITY.md` has a credential runbook**: bot token, web sign-in token,
  provider key, updater token and git token — how to revoke each, how to apply
  the replacement, and how to confirm the new one is live.
- **CI on every release tag**: the image is built, and native mode runs a real
  install → update → uninstall (`native-smoke.yml`, also weekly and on PRs that
  touch the installer, the updater or the units).
- `update.test.mjs` runs in CI.

### Fixed

- `README.md` gains "What 1.0 will mean" (the four promises) so the release
  policy is stated where a user meets it.
- An `.env` from an older release is covered by a test: missing keys are filled
  from defaults, and `--check` leaves the file untouched.

## 0.2.1-rc.2-0.6.0

### Fixed

- **A host-only deployment can update.** The updater probed the runtime at
  `DSH_BIND_IP:DSH_PORT` from *inside its own container*, where `127.0.0.1` is
  the updater: the probe answered `000`, the health gate failed and a healthy
  update was rolled back. Docker mode now probes the compose service (`dsh`),
  native mode the bound address, and `DSH_PUBLIC_URL` wins when set.
- **A rollback request can no longer lie.** `/trial/rollback` answered
  `200 {ok:true}` while the supervisor was busy and did nothing, and the
  connector retired the card on that answer. It answers `409`, or `202` when it
  accepts the job, and `/status` reports `busy`.
- **A full `/data` no longer kills the supervisor mid-rollback.** A failing
  state write inside `rollback()` was an unhandled rejection that exited the
  process. It is logged, the runtime still comes back, and the event stays in
  memory and in the log.
- **A hung update job cannot hold the only slot for ever.** `update.sh` and
  component jobs get a deadline (`DSH_UPDATE_TIMEOUT_SECONDS`, default 30
  minutes) and `POST /cancel`. Both signal the whole process group: `SIGTERM`
  to the shell alone left the real work (and its output pipes) alive, so the job
  stayed "building" after a cancel.
- **A native checkout sees new releases.** Its `origin` was the installer's
  directory, so once that clone was gone no new tag was ever fetched. It now
  points at the public remote, falls back to the local path when the fetch
  fails, and says which one it used.
- **`./update.sh --plugin` works in native mode.** A stray `local` outside a
  function made the branch fail under `set -e`.

- **Native updates work again.** `update.sh` ran `$DEPLOY_DIR/dsh-entrypoint`,
  which no installer creates (it links `/usr/local/bin/dsh-entrypoint`), so every
  native update, `update connector` and `--plugin` failed to prepare and rolled
  back. The launcher is now resolved (`DSH_ENTRYPOINT`, then
  `/usr/local/bin/dsh-entrypoint`, then the deployment directory).
- **`/system update all` really moves the connector tag in docker mode.**
  `DSH_SETUP_VERSION` was written only by the installer, and compose's `env_file`
  beats the image's `ENV`, so the entrypoint kept installing the previous
  connector tag. The update now rewrites it (and restores it on rollback).
- **Component changes reach the runtime.** `restart_runtime` used
  `docker compose restart`, which keeps the container environment `env_file`
  produced at create time; it now recreates with `up -d`.
- **A permission error no longer silences a group.** A 400 "not enough rights"
  was classified as "bot is not a member", which marked the bot missing and
  blocked the chat for an hour; the main bot was never re-checked. Only real
  membership failures do that now, and the main bot is reported instead of
  blocked.
- **Rollback snapshots are private.** `backups/self-*.tgz` holds `home/.dsh/git`
  with live git tokens and was world-readable; it is now `0600`.
- **A re-run keeps the deployment's mode.** `MODE` is read from the existing
  `.env` before the prompt, so `./install.sh`/`--yes` on a native host no longer
  falls back to docker and converts it.
- **A re-run applies its changes in native mode.** `systemctl enable --now`
  leaves a running unit alone; an active unit is restarted instead.
- **An exported variable no longer silently overrides `.env`.** The installer
  says so when `KEY` in the environment differs from the deployed value.
- **`127.0.0.1` is honoured in native mode.** The entrypoint always bound the
  default-route address, so a host-only install was still on the LAN.
- **The model default follows the provider** that was chosen, not the default
  provider, so `deepseek-official` no longer gets an opencode-go model.

### Added

- **`update.test.mjs`**: `update.sh` can be sourced and its helpers tested —
  the probe URL for every bind/mode combination, launcher resolution, the tag
  split, and a full docker `--self-to` with Docker stubbed, asserting the
  deployed version is rewritten, the runtime recreated, and both restored when
  the health gate fails.

- **`install.sh --uninstall [--purge]`** stops and removes the deployment, keeps
  `data/`, `.env` and `backups/` unless `--purge` is given, and prints what is
  left (service user, checkout).
- **The installer asks for the provider API key** and writes it under the name
  the chosen route reads (`OPENCODE_GO_API_KEY`/`DEEPSEEK_API_KEY`); the final
  summary says when a key is still missing, in both modes.
- **Native installs get `pnpm` and `--allow-scripts`,** the same two things the
  image installs: without them the Telegram adapter cannot build and the bash
  tool loses its native bindings.
- **The plan warns about web UI exposure** when it binds a non-loopback address:
  the UI is protected only by the sign-in token printed in the startup log.

### Changed

- `docs/LIMITS.md` and `SECURITY.md` describe what the updater can actually
  reach (it joins `default` and `design` to probe those services by name) and
  the new timeout/cancel behaviour instead of "no timeout and no cancel".

- Mode switching is documented as "stops the other mode, does not move data"
  (the two modes have different default directories); the installer stops a
  docker stack in any of the usual directories, not only `--dir`.
