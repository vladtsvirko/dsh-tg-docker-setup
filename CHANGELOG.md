# Changelog

The setup repo ships in lockstep with `dsh-telegram-connector`: `VERSION` is the
tag, the image tag and the connector tag at once. Connector-side changes are in
that repository's changelog; this file records what the installer, the
supervisor, the updater and the entrypoint changed.

Earlier releases are the git tags; this file starts at `0.2.1-rc.2-0.6.0`.

## 0.2.1-rc.5-0.8.1

> **After updating from 0.7.0, run `sudo ./install.sh --yes` once.** This release
> changes the systemd units (resource limits, `dsh-updater.service`
> `Restart=always`), and `update.sh` updates the checkout and the runtime but
> does not rewrite units.

**The Docker deployment mode is gone.** The setup now installs one thing: a
systemd service on this host. Docker is still installed and used for the
optional Penpot design stack, and nothing else. There is no migration path for
an old Docker deployment because there are none left; data is the same directory
tree, so pointing `--dir` at it is enough if one ever reappears.

### Added

- **A CPU/RAM share for the runtime.** The installer asks for a percent of the
  machine (default 30, `0` = unlimited) and writes `MemoryMax`, `CPUQuota` and
  `TasksMax=512` to `dsh.service`. A repair keeps `DSH_RESOURCE_PERCENT`.
- `install.sh --yes` is documented as the unattended path; `--mode` is gone.

### Changed

- `update.sh --self` is the only apply path: snapshot, checkout, install the
  matching DSH globally, prepare as the service user, restart, health gate,
  rollback by checkout + snapshot. No image build, no `self-previous`, no
  compose.
- `scripts/repair.sh` no longer has a Docker branch; it still accepts `--mode`
  for a 0.7.x caller and ignores it.
- `scripts/check-version.mjs` validates `VERSION` and the tag only; the DSH part
  is derived, so there is no Dockerfile or image tag to keep in step.
- `dsh-updater.service` uses `Restart=always`: after a successful apply the
  updater exits 0 to load the checkout it just installed, and `on-failure`
  left it dead until the next boot.
- The entrypoint's defaults and messages use `/srv/dsh/data` paths; the instance
  marker records `native`.
- Docs are written for the one deployment shape; `docs/PARITY.md` is gone.

### Fixed

- The updater reloads after an apply on a native host (see `Restart=always`).
- `install.sh` no longer asks for a deployment mode, and a `--check` run no
  longer reads or writes a container's UID/GID.

## 0.2.1-rc.5-0.7.0

A fixes release plus one feature: the installer can now hold several git
accounts, and it ends with a usable link instead of an origin that answers 401.

### Added

- **Several git accounts from the installer.** It asks for a host, HTTPS or
  SSH, and the credential (a PAT, the token `gh auth login` already stores, or
  a key it can generate and print for the deploy-key page). One account is
  written as `default`; two or more become host-scoped `hosts` entries, and a
  re-run merges instead of replacing. `GIT_PROFILES_FILE` copies a ready
  manifest for unattended installs. The generator learned `hosts`: HTTPS
  accounts get a `[credential "https://<host>"]` section, SSH accounts are
  picked by host through a generated wrapper, so keys no longer collide in one
  global `core.sshCommand`.

### Fixed

- **`--self-to` no longer bypasses the version policy.** The host path checked
  only "newer tag and descendant", so it could cross a DSH line or a product
  major with no flag while `/system update all` and `--self` refused. It now
  enforces the same rule and accepts
  `--i-know-versions-are-incompatible`; the updater passes that flag only after
  its own `/update` check accepted the crossing.
- **A repair keeps the deployed git author.** The prompt defaulted to the
  invoking user's global identity — `root` when the installer ran under `sudo` —
  and rewrote `data/home/.gitconfig` on every run. It now prefers the deployed
  config, then the `SUDO_USER`'s identity, so an ordinary re-run keeps the
  agent's commits as they were.
- **The native generator actually runs.** Node resolves a symlinked entry point
  to its real path, so the CLI check compared `/usr/local/bin/dsh-git-credentials.mjs`
  with the checkout path, concluded "imported, not executed", and exited 0
  without writing anything. It now compares real paths; a regression test runs
  it through a symlink.
- **Native installs link the git credential generator.** `link_bins` never
  created `/usr/local/bin/dsh-git-credentials.mjs`, so on a native host the
  entrypoint's call failed at every boot and no git credentials were applied,
  even with a valid manifest.
- **The sudo re-exec keeps the mode answer.** `MODE`, `TIER` and `DESIGN` are
  passed through, so a native install no longer re-asks the mode with the docker
  default after escalating.

### Changed

- **The install summary prints the signed web URL.** The runtime's `?token=`
  link is read back from its own log; the bare origin (401) is only the fallback
  when the log cannot be read. The summary also says whether Telegram is
  configured, instead of always telling a web-only deployment to send `/web`.
- The compose `updater` service now receives
  `DSH_UPDATE_TIMEOUT_SECONDS` (default 1800), so the apply deadline is tunable
  from `.env` without handing it the whole environment.
- `image-build.yml` builds the updater image too; a tag build checks that the
  matching connector tag exists (`git ls-remote`), the one coupling rule no
  local script could verify.
- `components.json` pins `dsh-penpot-plugin#v0.1.1`, whose release documents the
  setup's design component as the primary install path.

## 0.2.1-rc.5-0.6.4

### Fixed

- **The instance marker was invalid JSON.** An editing pass dropped the `$` in
  `entrypoint.sh`, so the marker read
  `{"id":"…","mode":"native","pid":,"version":"…"}` — no process id, unparseable.
  Nothing failed visibly: the flock guard still held, but the doctor could not
  name the holder (`stale marker from pid ?`) and the connector could not tell
  its own runtime from a foreign one, so every held session fell back to the
  "web UI tab" advice. The pid is now written with `$` and through `%s`, which
  cannot produce invalid JSON even if a value goes missing.
- **The doctor says what an unreadable marker means.** A marker without a pid is
  now a warning that names the fix (`restart dsh.service to rewrite it`) instead
  of a stale-pid message with a question mark.

### Added

- `node --test` now boots the real `entrypoint.sh serve` with stubbed binaries and
  asserts the marker parses, carries this pid and an id, and that a second
  runtime over the same data directory is refused with the holder named. That
  test fails on the broken marker, which is how this was found after release.

## 0.2.1-rc.5-0.6.3

### Fixed

- **The doctor fixture assumed uid 1000.** The installer records the invoking
  user's ids in `.env`, and the doctor compares them with the data directory it
  created; a CI runner is uid **1001**, so the fixture's hardcoded `1000` made
  the ownership check fail on CI while passing locally. The fixture now reads
  `process.getuid()`/`getgid()`, and a new test pins the mismatch itself (a data
  directory owned by another user is a failure, with the expected/actual ids in
  the message).

`v0.2.1-rc.5-0.6.2` fixed the credential helper's YAML dependency and the Docker
daemon assumption; this is the third environment assumption in the same fixture,
and the last one the local machine differs on.

## 0.2.1-rc.5-0.6.2

### Fixed

- **The credential helper no longer needs a YAML library.** `scripts/credentials.mjs`
  resolved `yaml` from the global dsh install, so it worked on a deployment and
  failed in CI (which has no global dsh) — exactly the bootstrap case the helper
  exists for. It now edits the fixed `version`/`refs`/`records` document shape
  directly: values are written as double-quoted YAML scalars, comments and
  `records` survive byte for byte, an unreadable or unversioned document is
  refused instead of rewritten, and a fresh file gets the `version: 1` header the
  runtime requires. Verified against the runtime's own parser.
- **The doctor test no longer reads the machine it runs on.** A CI runner has a
  working Docker daemon, so `docker compose ps` against the throwaway fixture
  answered "no container" and the doctor reported a failure where the test
  expected the "docker is absent" warning. The test shadows `docker` with one
  that is installed but unusable.

`v0.2.1-rc.5-0.6.1` carried the first half of this (the Docker shim) and is
superseded: its CI stayed red on the credential tests. No runtime behaviour
changed in either patch.

## 0.2.1-rc.5-0.6.1

### Fixed

- The new doctor test read the machine it ran on. A CI runner has a working
  Docker daemon, so `docker compose ps` against the throwaway fixture answered
  "no container" and `repair.sh` reported a **failure** where the test expected
  the "docker is absent" warning. The test now shadows `docker` with one that is
  installed but unusable (`docker info` exits 1), which is the contract it was
  written for; the product code is unchanged. Tagged because the setup CI must be
  green for the tag it released.

## 0.2.1-rc.5-0.6.0

The release that makes a repair run safe and makes a second runtime impossible
to leave behind. Both were visible as "model calls stopped working" and "the web
UI lost my workspace" after `systemctl restart` / `docker compose restart`.

### Fixed

- **A repair run keeps the provider key it already has.** `install.sh` prompted
  for `OPENCODE_GO_API_KEY` on every run and wrote the answer to `.env`, while
  the runtime resolves a credential stored by the web UI's Models page *before*
  the environment. One deployment could therefore hold two keys, the older one
  winning, and model calls failed with a credential nobody remembered setting.
  The installer now reads the deployed key and keeps it (a new `--rotate-key`
  asks only when you mean to replace it), writes one key variable per provider
  route, and reconciles an existing `.credentials.yaml` to the `.env` value
  (backup kept, 0600). It also reports a stored key that `.env` does not have.
- **`.env` can no longer contain the same key twice.** A fresh Docker deployment
  copied `.env.example` and then appended the managed values, so the file kept a
  sample `OPENCODE_GO_API_KEY=` near the top and the real one at the bottom —
  the runtime reads the last assignment, which is not the line the file invites
  you to edit. The copy now drops sample assignments and keeps the comments.
- **The installer no longer prompts for mode from a stale file.** `--dir` is
  consulted before the checkout's own `.env` when deciding the deployment mode.

### Added

- **`./install.sh --doctor` and `./update.sh --doctor`** run the same checks in
  both modes, and `--fix` repairs the safe subset: duplicate or CRLF `.env`
  assignments, a world-readable `.env`, a provider key the web UI shadows, a
  duplicated managed block in the profile patch, a data directory owned by the
  wrong user, and a missing `DSH_SETUP_VERSION`. It also reads the workspace
  document the web UI lists: one that does not parse (the registry plugin then
  fails to activate and the UI shows nothing) is a failure naming the snapshot
  that restores it, and a workspace whose directory vanished is a warning. Every install and every
  successful self-update runs it with `--fix`, so a half-broken file is repaired
  instead of reported next time.
- **One runtime per data directory.** The entrypoint takes a kernel lock on
  `data/.runtime.lock` and writes `data/.runtime.json` with its mode and pid. A
  second runtime over the same `data` (a native service beside the Docker stack,
  or two containers from two checkouts) waits 20 s and then refuses to start with
  the holder's mode and pid. That state is the one failure a restart cannot
  clear: each process holds the other's session write handles, the web UIs
  disagree about the workspace list, and Telegram reports "held by another
  client". The doctor reports a live marker from a different mode as a failure.
  The marker carries an instance id, exported to the runtime, because the plugin
  runs in a child process whose pid is not the one in the marker.
- **`docs/PARITY.md`** states the native-first rule and the full table of what is
  identical, what is intentionally different, and how a feature is added so the
  two modes cannot drift silently.

## 0.2.1-rc.5-0.5.1

### Fixed

- The installer test that pins "choosing the design stack installs Docker" read
  the host it ran on: the CI runner has Docker, so the plan said "docker present"
  where the test expected an install. It now shadows `docker` with a failing stub,
  which makes the plan the same everywhere.

## 0.2.1-rc.5-0.5.0

### Added

- **The installer configures git.** The agent commits, and a commit without an
  author fails, so it now asks for the git author name and email (defaulting to
  the host's own `git config`, then to the login user and `user@host`) and writes
  them into the runtime's `~/.gitconfig`.
- **Repository access is asked for, not just documented.** A provider
  (`github`, `gitlab`, `gitea`, `forgejo`, `self-hosted`) and a token are enough
  for the agent to clone and push private repositories: the installer writes
  `secrets/git/profiles.json` (0600, owned by the runtime user) — the manifest
  `docs/GIT.md` describes and `git-credentials.mjs` consumes. Native installs
  keep it at `<dir>/secrets/git` and the unit points `DSH_GIT_SECRETS` there.
- **`scripts/git-profile.sh`** is sourced and tested on its own: JSON escaping,
  the self-hosted host, the 0600 file, a backup on rewrite, and a refusal to
  leave an unparseable manifest behind.
- **Docker is installed when something needs it.** Choosing the Penpot design
  stack installs Docker even in native mode — the runtime stays container-less,
  the stack is not — instead of skipping the stack with a warning while leaving
  the plugin enabled against a backend that does not exist. When Docker is absent
  and *not* needed, the installer offers to install it (default: no).

### Changed

- `git` is installed without asking: both modes need it, and `--no-deps` remains
  the escape hatch for hosts that manage their own packages.
- The install plan now shows `git: Name <email>`, `git auth: github (token stored
  in …)` and the dependency line names git, Docker and Node separately.

### Notes

- `install.example.env` accepts `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`,
  `GIT_PROVIDER`, `GIT_HOST` and `GIT_TOKEN` for unattended installs.

## 0.2.1-rc.5-0.4.0

### Added

- **The firewall advisory is actionable from Telegram, not only from a shell.**
  0.3.0 printed the rule at install and update time; a blocked port still needed
  SSH to fix. The updater now answers `/firewall` (GET: the ports this
  deployment serves, their networks and whether ufw allows them) and
  `/firewall allow <port>` (POST: run the fixed rule). The connector renders
  both, and the finished-update report appends the advisory, so the blocked
  state arrives without a `--status` command.

  The privileged call stays bounded: the port must be one the deployment
  already serves from its `.env`, the network is derived from `DSH_BIND_IP`, and
  the only command the updater runs is `ufw allow from <network> to any port
  <port> proto tcp`. Native mode only — docker deployments report
  "nothing to do", because a published port never reaches `INPUT`.

## 0.2.1-rc.5-0.3.0

### Added

- **A native install and update say when ufw would block the web UI.** A
  systemd service is gated by ufw's `INPUT` chain; a published Docker port is
  not, because Docker DNATs it in `nat`/`FORWARD` before `INPUT` is consulted.
  The check is therefore native-only by construction. It names the rule to
  paste, with the network taken from the interface that carries
  `DSH_BIND_IP` instead of a guessed range:

  ```
  sudo ufw allow from 192.168.2.0/24 to any port 4310 proto tcp
  ```

  Nothing is changed: the installer cannot know whether a port should be
  LAN-only, VPN-only or tunnel-only, and a ufw rule outlives `--uninstall`.
  Silent when ufw is absent or inactive, when the bind is loopback, or when a
  rule already allows the port. `--check` run unprivileged (no passwordless
  `sudo`) still reports that ufw is enabled — the enable flag in
  `/etc/ufw/ufw.conf` is world-readable — and says the rules need root rather
  than claiming a port is closed.

  Sites: the install plan before the `Proceed?` prompt, the end of
  `native_apply` for `--yes` runs, and `update.sh`'s `verify` and `status`.

## 0.2.1-rc.5-0.2.2

### Fixed

- **A native install no longer enables the design plugin against a backend that
  cannot exist.** `--design docker` was honoured even in native mode, which has
  no Docker: the Penpot stack was skipped with a warning, but `.env` still said
  `PENPOT_ENABLED=1`, so the plugin mounted and failed on every boot
  (`no Penpot backend available … 1 entry did not activate`). Native now refuses
  the stack up front and says so; the plugin stays off.
- **`verify` only reads the log of the current start.** It grepped the last 200
  lines of the unit's journal, so a plugin failure from a *previous* boot made a
  healthy update report "verification complained" — and kept reporting it on
  every later update. Native uses `ActiveEnterTimestamp`, docker uses
  `--since 2m`.

### Notes

- To enable the design tools later in native mode, point the plugin at an
  existing Penpot (`PENPOT_API_URL`, `PENPOT_ACCESS_TOKEN`, `PENPOT_ENABLED=1`);
  the stack itself is a Docker component.

## 0.2.1-rc.5-0.2.1

### Fixed

- **The unattended install aborted while writing `.env`.** `DSH_TELEGRAM_PUBLISHER_TOKENS`
  was used before it was initialised, and `set -u` turns that into an error at
  the one step `--check` never reaches — so every `--check` stayed green while
  `--yes` failed. It is initialised with the other answers, and a test now
  asserts that every variable `write_env` persists is initialised (the same
  mistake had already happened once with `DSH_ADMIN_USER_ID`).

## 0.2.1-rc.5-0.2.0

### Added

- **The installer asks for publisher bots.** `DSH_TELEGRAM_PUBLISHER_TOKENS`
  existed only in `.env.example`, so a native install — which starts from an
  empty `.env` — never had the line and a new user had no way to discover it.
  It is now asked with the bot token, written to `.env`, accepted in
  `install.example.env`, and the plan reports `bots: main + N publisher(s)`.
  One bot has one budget (~20 messages/minute per group, shared by every topic);
  extra senders multiply it, and each must be a member of the group.
- **The installer says which directory is the deployment.** `curl … | bash`
  leaves the fetched release behind (`~/dsh-setup` by default), and native mode
  installs elsewhere (`/srv/dsh`), so the download looked like the deployment.
  The summary now names it, offers to remove it (default: keep), and
  `--clean-source` removes it without asking. It refuses to remove a checkout
  the deployment updates *from* (a local `git remote`), because that would cut
  `/system update all` off from new releases.

### Notes

- `install.example.env` also documents `DSH_ADMIN_USER_ID`, which was asked for
  but absent from the answers file.

## 0.2.1-rc.5-0.1.2

### Fixed

- The test that guards the root-before-questions order assumed a host without a
  usable Docker, so it failed on CI runners (which have one) while passing
  everywhere else. It now skips when Docker is usable, and the release exists so
  the tag's CI is green.

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
