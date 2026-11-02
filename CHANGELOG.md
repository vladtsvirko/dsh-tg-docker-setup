# Changelog

The setup repo ships in lockstep with `dsh-telegram-connector`: `VERSION` is the
tag, the image tag and the connector tag at once. Connector-side changes are in
that repository's changelog; this file records what the installer, the
supervisor, the updater and the entrypoint changed.

Earlier releases are the git tags `v0.2.1-rc.2-0.1.x` … `v0.2.1-rc.2-0.4.11`;
this file starts here.

## Unreleased

### Fixed

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

- Mode switching is documented as "stops the other mode, does not move data"
  (the two modes have different default directories); the installer stops a
  docker stack in any of the usual directories, not only `--dir`.
