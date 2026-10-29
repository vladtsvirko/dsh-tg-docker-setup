# Setup updater

`/system update all` drains all agents, then asks a privileged `updater`
sidecar to move the setup to a release tag. The updater stops the runtime,
snapshots state, starts the new image, and rolls back on failure. It reports
the result to the control chat itself.

## Shape

```
Telegram user
   │ /system update all
   ▼
connector (dsh, uid 1000)
   ├─ UPDATING, blocks prompts
   ├─ waits agents.list() all idle (web UI + Telegram)
   ├─ POST http://updater:8787/update   (ops network, bearer token)
   │     ← 202 {job, from, target}
   └─ may be stopped by the updater
          │
          ▼
updater (DSH_UID + docker group, raw socket)
   ├─ validate token/mode/target
   ├─ send "update started" via Bot API
   ├─ bash update.sh --self-to <target>
   │    ├─ checkout target
   │    ├─ build dsh while old runs
   │    ├─ stop dsh (freeze)
   │    ├─ snapshot data/home + data/supervisor
   │    ├─ start new dsh
   │    ├─ health/verify
   │    └─ on failure: restore snapshot + previous image
   └─ send success/rollback + log tail
```

Networks:

```
ops (internal): dsh, updater      endpoint :8787, token, no published port
default:        dsh, updater      egress (Telegram, git, image pulls)
```

The updater runs as `DSH_UID:DSH_GID` with `DSH_DOCKER_GID` added to its groups.
It is not root, but the Docker socket makes it host-root-equivalent.

## Endpoint

```
POST /update
Authorization: Bearer <DSH_UPDATER_TOKEN>

{"mode":"compatible"}                 latest tag, same DSH + product major
{"mode":"available"}                  latest tag overall
{"mode":"exact","version":"v…"}       named tag, not older than current

202 {"job":"...","from":"...","target":"..."}
400 bad body | 401 bad token | 409 busy/not on a tag
422 no compatible target / unknown / older
```

```
GET /health   {ok, tag, canApply}
GET /status   {job: {id, state, from, target, exitCode?, logTail?}}
```

There is no result-polling requirement for the connector: the updater reports
directly. The connector watches `/status` while it is still alive so a failure
before the stop unblocks it.

## Modes and versions

Tags are `<dsh>-<major>.<minor>.<patch>`; `0.x` is the compatible line, a major
bump is a break. The product part resets to `0.0.0` on a new DSH alignment.

- `compatible`: same DSH part and same product major; latest wins; compatible
  releases may be skipped.
- `available`: latest overall; `/system update all --i-know-versions-are-incompatible`.
- `exact`: the updater's explicit target; not older than the running tag.
- `rollback` mode is deliberately not exposed yet.

The image tag, `VERSION`, the connector pin and the Dockerfile DSH version are
all hardcoded in a setup release; CI checks they agree.

## Drain

The connector:

1. sets `bindings.update` (persisted), `UPDATING`;
2. blocks prompts with one auto-reply per chat per minute;
3. polls `agents.list()` until every agent is `idle` (web UI included);
4. calls `/update` only then.

There is no timeout and no cancel after the request. `/system status` lists the
sessions still running. A web turn can still start in the instant before the
updater stops the container; that best-effort race is accepted.

After a restart, the first Telegram update batch is treated as “arrived during
the update”: each allowed sender gets one “update finished — send it again”
reply, and none of those messages are executed.

## Report

Plain text to the control chat (`controlChatId` from
`data/home/telegram-connector/bindings.json`), token from
`DSH_TELEGRAM_BOT_TOKEN`:

- `update started: from → target`
- `update finished: target (DSH …)`
- `update failed and rolled back to from` plus the last 20 log lines
- Telegram token redaction is applied to the log tail.

## Rollback and data

One previous image (`dsh-backend:self-previous`) and one
`backups/self-*.tgz` (home + supervisor) are kept. On failed health:

```
stop new dsh → restore snapshot → checkout previous tag
→ retag previous image → start previous → verify → report
```

`data/workspace` is never snapshotted or restored. Data created after the
snapshot is lost if a rollback restores it; that is the cost of a consistent
freeze.

## Operating

```sh
# .env
DSH_UPDATER_TOKEN=<random>
DSH_DOCKER_GID=$(getent group docker | cut -d: -f3)

docker compose build
docker compose up -d
docker compose logs -f updater
```

`/system update all` in the bot control chat. If the token is empty, the
connector prints the host commands instead of calling the updater.

## Test plan

Unit (no Docker):

```sh
node --test updater.test.mjs
```

Fake apply (no real dsh):

- a temporary git repo with two tags and a fake `update.sh` that prints
  `building/stopping/starting` and exits 0;
- `POST /update`, then `GET /status` shows `done` and the log tail.

Real stack, disposable setup:

1. Set `DSH_UPDATER_TOKEN` and the correct `DSH_DOCKER_GID`.
2. `docker compose build && up -d`; `GET /health` over the ops network.
3. `/system update all` with one idle session: it drains, reports started, the
   container restarts, and the updater reports the new version.
4. Break a target on purpose (bad healthcheck or startup) and verify:
   stop, snapshot restore, previous image, “rolled back” report with log tail.
5. Send a message while `dsh` is down; after boot it is answered once and not
   executed.

## Security

- No published updater port; bearer token on the internal `ops` network.
- Fixed action only: the request selects a tag/mode, never a command.
- Raw Docker socket: compromising the updater compromises the host.
- The connector never receives the socket.
- `DSH_UPDATER_TOKEN` and `DSH_DOCKER_GID` are the only new operational secrets.

## Limits

- Best-effort drain race with a new web turn.
- No timeout/cancel after the request; a stuck session blocks the update.
- The updater is not self-updated by `--self`; its new image applies on the next
  host `docker compose build && up -d`.
- A crash of the updater mid-apply is not automatically recovered; the result
  file and container state are the recovery inputs.
