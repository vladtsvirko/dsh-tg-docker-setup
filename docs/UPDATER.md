# Setup updater

`/system update setup` posts a confirmation card with the target and the number
of running sessions. **Update now** drains all agents, then asks a privileged
updater service to move the setup to a release tag; nothing is applied before
that button. The updater snapshots state, checks out the
tag, installs the matching DSH, restarts the runtime, and rolls back on failure.
It reports the result to the control chat itself.

This is the normal no-SSH path. Version rules are in
[`VERSIONS.md`](VERSIONS.md); the full boundary of what this cannot fix is in
[`LIMITS.md`](LIMITS.md).

## Shape

```
Telegram user
   │ /system update setup
   ▼
connector (dsh.service, user dsh)
   ├─ UPDATING, blocks prompts
   ├─ waits agents.list() all idle (web UI + Telegram)
   ├─ POST http://127.0.0.1:8787/update   (bearer token)
   │     ← 202 {job, from, target}
   └─ may be stopped by the updater
          │
          ▼
dsh-updater.service (root, 127.0.0.1:8787)
   ├─ validate token/mode/target
   ├─ send "update started" via Bot API
   ├─ bash update.sh --to <target>
   │    ├─ snapshot data/home + data/supervisor
   │    ├─ checkout target
   │    ├─ install @deepseek-ai/dsh@<DSH part> when it changes
   │    ├─ prepare the profile as dsh
   │    ├─ restart dsh.service
   │    ├─ health/verify
   │    └─ on failure: restore snapshot + previous tag
   └─ send success/rollback + log tail
```

The updater is a systemd unit. It binds `127.0.0.1:8787` only, so there is no
published port. It runs with `DSH_UPDATER_TOKEN` from `.env`; an empty token
makes it refuse every apply.

It is root because restarting `dsh.service` requires it — that is the only
reason. The runtime stays the unprivileged `dsh` user, and it never restarts
itself. The updater runs from the checkout (`node updater.mjs`), so a setup
update changes its code on its next start.

## Endpoint

```
POST /update
Authorization: Bearer <DSH_UPDATER_TOKEN>

{"mode":"compatible"}                 latest tag, same DSH + product major
{"mode":"available"}                  latest tag overall
{"mode":"exact","version":"v…"}       named tag, not older than current

202 {"job":"...","from":"...","target":"..."}
400 bad body | 401 bad token | 409 busy/not on a tag
422 no compatible target / unknown / older / crossing without the flag
503 updater disabled
```

```
POST /target   {mode} -> 200 {from, target, crosses, dshFrom, dshTo, commits}   (resolve without applying)
GET  /health   {ok, tag, canApply}
GET  /status   {job: {id, state, from, target, exitCode?, logTail?},
                elapsedSeconds, timeoutSeconds, cancellable}
GET  /components                      {components: [{name,label,enabled,port}]}
POST /components {name,action,port?}   enable|disable|configure -> 202 {job}
POST /cancel                           stop the running job
GET  /firewall                         ufw state for the ports this deployment serves
POST /firewall {port}                  allow one served port from its network
```

There is no result-polling requirement for the connector: the updater reports
directly. The connector watches `/status` while it is still alive so a failure
before the restart unblocks it.

## Modes and versions

Tags are `<dsh>-<major>.<minor>.<patch>`; `0.x` is the compatible line, a major
bump is a break. The product part resets to `0.0.0` on a new DSH alignment.

- `compatible`: same DSH part and same product major; latest wins; compatible
  releases may be skipped. This is what `/system update setup` uses by default.
- `available`: latest overall. Reached only with the explicit
  `/system update setup --i-know-versions-are-incompatible`; it may cross a DSH
  line or product major.
- `exact`: the updater's explicit target; must be newer than the current tag,
  never an older one. The apply step (`update.sh --to`) additionally
  refuses a tag that is not a descendant of the running one.
- `rollback` mode is deliberately not exposed. A failed health gate rolls back
  automatically; a manual tag rollback is a host operation.

`VERSION` is the release: its prefix is the DSH part that `update.sh` installs
globally, and the entrypoint derives the connector tag from
`DSH_SETUP_VERSION`. CI checks that `VERSION` and the tag agree. The setup
release and connector release move together — see [`VERSIONS.md`](VERSIONS.md).

## Drain

The connector:

1. sets `bindings.update` (persisted), `UPDATING`;
2. blocks prompts with one auto-reply per chat per minute;
3. polls `agents.list()` until every agent is `idle` (web UI included);
4. calls `/update` only then.

The connector first asks `/target` and posts one editable card in the control
chat: `from → target`, live blocker count/list, and a **Cancel** button. While
the card is still draining, Cancel deletes the update state and edits the card
to “cancelled”. Once `/update` returns 202 the **button** is removed (the
runtime's restart is imminent), but the job remains cancellable: `/system
cancel` calls the updater's `POST /cancel`, which stops the job with `SIGTERM`
and `SIGKILL` after ten seconds. Older updaters without `/target` fall back to
`/update` and update the card with the accepted target.

A running job also has a deadline, `DSH_UPDATE_TIMEOUT_SECONDS` (default 30
minutes): on expiry it is stopped the same way and reported as timed out.
`/system status` lists the sessions still running. A web turn can still start in
the instant before the updater restarts the service; that best-effort race is
accepted.

After a restart, the first Telegram update batch is treated as “arrived during
the update”. Plain prompts and attachments in it are delivered; commands are
refused with one “update finished — commands sent while it restarted are not
executed; send it again” reply per sender, because a queued `/system …` or trial
confirmation refers to the state the update replaced.

## Report

Plain text to the control chat (`controlChatId` from
`data/home/telegram-connector/bindings.json`), token from
`DSH_TELEGRAM_BOT_TOKEN`:

- `dsh is down — update in progress` when the stop phase begins
- `system update finished: from → target (DSH …)`
- `system update failed and rolled back to from` plus the last 20 log lines
- `system update failed (exit N)` / `cancelled` / `timed out` when the apply did
  not reach a clean rollback
- a ufw note when a port this deployment serves is blocked
- Telegram token redaction is applied to the log tail.

If the updater cannot post the report, it leaves `data/update/result.json`
behind. The booting connector waits for a terminal state and sends the persisted
result instead. The update card is closed with the same outcome.

## Rollback and data

The updater keeps one `backups/self-*.tgz` (home + supervisor). On failed
health, including an active unit whose **web port** does not answer:

```
restore snapshot → check out previous tag → rewrite DSH_SETUP_VERSION
→ restart dsh.service → verify → report
```

Rollback restores the previous checkout and the snapshot; it does not undo
changes to `data/workspace`.

`data/workspace` is never snapshotted or restored. Data created under
`data/home` or `data/supervisor` after the snapshot is lost if a rollback restores
it; that is the cost of a consistent freeze. Workspace changes made by the failed
deployment remain.

## Operating

```sh
# .env
DSH_UPDATER_TOKEN=<random>

systemctl status dsh-updater.service
journalctl -u dsh-updater.service -f
```

`/system update setup` in the bot control chat. If the token is empty, the
connector prints the host commands instead of calling the updater.

## Test plan

Unit (no host changes):

```sh
node --test updater.test.mjs
```

Fake apply (no real dsh):

- a temporary git repo with two tags and a fake `update.sh` that prints
  `snapshot/checkout/restart` and exits 0;
- `POST /update`, then `GET /status` shows `done` and the log tail.

Real stack, disposable setup:

1. Set `DSH_UPDATER_TOKEN` (the installer writes one).
2. `systemctl start dsh-updater.service`; check
   `curl -H "Authorization: Bearer $DSH_UPDATER_TOKEN" http://127.0.0.1:8787/health`.
3. `/system update setup` with one idle session: it drains, reports started, the
   service restarts, and the updater reports the new version.
4. Break a target on purpose (a service that cannot start, or a web bind that
   does not answer) and verify: snapshot restore, previous tag checkout,
   “rolled back” report with log tail.
5. Send a message while `dsh` is down; after boot it is answered once and not
   executed.

## Security

- No published port; loopback only, bearer token.
- Fixed action only: the request selects a tag/mode, never a command.
- Root service: compromising the updater compromises the host.
- The runtime cannot restart its own unit; only the updater may.
- `DSH_UPDATER_TOKEN` is the only new operational secret.

## Limits

- Best-effort drain race with a new web turn.
- The job deadline and `/system cancel` stop the apply, but neither can undo a
  half-applied checkout; the snapshot and the previous checkout are the recovery
  inputs. A stuck session blocks the drain, not the apply.
- The updater's **code** is the checkout it runs, but its **unit** is not
  rewritten by `--apply`. A change to the unit needs `sudo ./install.sh --yes`
  (idempotent; it keeps `.env`), not an update.
- A crash of the updater mid-apply is not automatically resumed. `result.json`,
  the checkout and the snapshot are the recovery inputs.
- The updater cannot fix a dead systemd, a corrupt checkout, a full disk, a
  broken `.env`, or a runtime that cannot boot at all. Those need the host; see
  [`LIMITS.md`](LIMITS.md).
- Telegram is the only normal control path. If the connector cannot load or
  cannot reach Telegram, the update card is unreachable even though the updater
  may still be running.
