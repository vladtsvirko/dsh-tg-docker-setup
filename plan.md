# Plan: rollbackable setup update via updater sidecar

Status: design approved, implementation not started.
Owner: setup repo + connector repo.
Related: `docs/SELF-UPDATE.md`, `AGENTS.md`, `docs/GIT.md`.

## Goal

`/system update all` in the bot drains all agents, then asks a privileged
**updater** sidecar to move the setup checkout to a target release, rebuild,
stop the old container, snapshot state, start the new one, and roll back on
failure. The updater reports the result to the control chat itself.

## Locked decisions

| Topic | Decision |
|---|---|
| Rollback depth | one previous image + one data snapshot |
| Downtime | accepted; stop old before starting new |
| Drain scope | all agents, including web UI (`agents.list()`) |
| Drain guarantee | best-effort: wait idle, then stop; a new web turn can race (accepted) |
| Timeout/cancel | none after the request; `/system status` shows blockers |
| Report | updater sends via Bot API; control chat only |
| Request channel | internal HTTP on a dedicated `ops` network, bearer token |
| Docker access | raw socket in the updater; no proxy |
| Version source | setup release hardcodes DSH version and image tag; `.env` no `DSH_VERSION` |
| Mode policy | `compatible` (same DSH + same product major), `available` (latest), `exact` (not older), `rollback` later |
| Old connector commands | removed; only `/system …` |

## Architecture

```
Telegram user
   │ /system update all
   ▼
connector (dsh, uid 1000)
   ├─ UPDATING=true, block prompts
   ├─ wait agents.list() all idle (web + Telegram)
   ├─ POST http://updater:8787/update  (ops network, token)
   │     ← 202 {job, from, target}
   └─ persists update start; may be stopped
          │
          ▼
updater (root, docker.sock, repo at same absolute path)
   ├─ validate token/mode/target
   ├─ send "update in progress" via Bot API (send-only)
   ├─ git fetch/checkout target
   ├─ docker compose build dsh        (old still running)
   ├─ docker compose stop dsh         ← state frozen
   ├─ tar data/home + data/supervisor ← one snapshot
   ├─ docker compose up -d dsh
   ├─ health + web + connector-connected check
   ├─ success → report; failure → restore, checkout previous, start, report
   └─ never accepts arbitrary commands
```

Networks:

```
ops (internal):  dsh, updater        endpoint :8787, token
default:         dsh, updater        egress (Telegram, git, images)
```

No published updater port.

## Version contract

```
VERSION:     0.2.1-rc.2-0.0.1
tag:         v0.2.1-rc.2-0.0.1
image:       dsh-backend:0.2.1-rc.2-0.0.1
Dockerfile:  ARG DSH_VERSION=0.2.1-rc.2
```

- Same product major + same DSH part = compatible; may jump.
- Different major or DSH part needs `--i-know-versions-are-incompatible`.
- Exact mode may not go below the running version; rollback mode is separate.
- CI checks tag ↔ `VERSION` ↔ image tag ↔ Dockerfile DSH arg.
- `.env` loses `DSH_VERSION`.

## Slices

### Slice 1 — updater service and endpoint

- [x] `updater.mjs`: HTTP server, token auth, `/health`, `/update`, `/status`.
- [x] Target resolution: current tag, compatible/available/exact, git tag ordering.
- [x] `updater.Dockerfile`: node + docker CLI + compose + git + tar.
- [x] Compose: `updater` service, `ops` internal network, same-path repo mount,
      socket, env, `expose: 8787`, no `ports`.
- [x] `.env.example`: `DSH_UPDATER_TOKEN` (host path comes from `${PWD}`).
- [x] Unit tests for target resolution and endpoint validation; no Docker required.
- Acceptance: `POST /update` returns 202 with target; bad token/mode/tag rejected;
  `GET /status` reports state; no update is executed yet. **met** (apply is intentionally absent).

### Slice 2 — apply and report

- [x] Extend `update.sh` with `--self-to <tag>` for the updater (modes resolved by the updater).
- [x] Updater spawns `update.sh --self-to <target>`, captures output, tracks state.
- [x] `git fetch/checkout`, build while old runs, stop, snapshot, start, health.
- [x] One previous image retained; rollback restores checkout + image + snapshot.
- [x] Updater sends success/rollback report via Bot API:
      token from `.env`, `controlChatId` from `data/telegram-connector/bindings.json`.
- [x] Log tail included, truncated; no secrets.
- [x] Updater runs as `DSH_UID:DSH_GID` with `DSH_DOCKER_GID`, not root.
- Acceptance: code path implemented; live failed-health rollback still needs a
  real stack test. Successful apply path tested with a fake `update.sh`.

### Slice 3 — connector drain and request

- [x] `UPDATING` state persisted; cleared on boot.
- [x] Block ordinary prompts on all surfaces; one auto-reply per chat.
- [x] Drain via `agents.list()` (web + Telegram) until all `idle`.
- [x] `/system status` lists blocking sessions while draining.
- [x] `POST /update` only after idle; 202 or error handling.
- [x] On boot after an update, auto-reply to queued messages older than the update
      (“update finished — send it again”) and advance the offset.
- [x] `/system update all` compatible; flag for available; exact/rollback not in chat.
- [x] Watches updater status while dsh is still running, so a pre-stop failure
      unblocks the connector.
- Acceptance: code path implemented; live multi-agent drain and downtime queue
  still need a real-stack test.

### Slice 4 — hardcode versions and remove DSH_VERSION

- [x] `compose.yaml` hardcodes `dsh-backend:<setup-version>` for init + dsh.
- [x] `Dockerfile` hardcodes `ARG DSH_VERSION=<dsh>`; no default from `.env`.
- [x] Remove `DSH_VERSION` from `.env.example`; document that old values are ignored.
- [x] `update.sh` image selection uses `VERSION`/compose, not env.
- [x] Remove `--apply`/`--rollback` DSH-only modes or repurpose them.
- [x] CI/AGENTS checks for image tag ↔ VERSION ↔ Dockerfile.
- [x] Entrypoint reinstalls the connector when the pinned ref changes.
- Acceptance: `docker compose config` has no version from `.env`; CI validates.

### Slice 5 — docs and test plan

- [x] `docs/UPDATER.md`: endpoint, token, network, reports, rollback, limits.
- [x] README: updater token/GID, sidecar security, docs link.
- [x] AGENTS release notes.
- [x] Dry-run test plan: fake target, failed health, rollback, queued messages.
- [x] Update `docs/SELF-UPDATE.md` for the new flow and version hardcoding.

## API contract

```
POST /update
Authorization: Bearer <DSH_UPDATER_TOKEN>
{"mode":"compatible"}
{"mode":"available"}
{"mode":"exact","version":"v0.2.1-rc.2-0.0.2"}

202 {"job":"...","from":"...","target":"..."}
400 bad body
401 bad token
409 busy / updater not ready
422 no compatible target / tag unknown / older than current

GET /health   -> {ok, tag}
GET /status   -> {state, job, from, target, startedAt, logTail?}
```

State: `idle | accepted | building | stopping | starting | verifying | done | rolling-back | rolled-back | failed`.

## Data and report

```
data/update/            updater-owned durable state (not IPC)
  result.json
  updater.log
data/backups/
  self-<stamp>.tgz      data/home + data/supervisor
```

Report: plain text to control chat. No result polling required.

## Risks / open items

- Best-effort drain race with a new web turn (accepted).
- No timeout: a stuck session blocks the update forever; status shows it.
- Updater has raw Docker socket = host root-equivalent, even as non-root.
- `DSH_DOCKER_GID` must match the host docker group.
- Data restore loses sessions created after the snapshot; only used on failed
  boot/rollback.
- Rollback to a connector version without the report client: the updater reports
  directly, so this is covered.
- Updater updates `dsh` only; its own new image applies on the next host compose up.
- The updater repo mount uses `${PWD}`; run `docker compose` from the setup
  directory, otherwise the same-path mount and compose-inside-container paths
  break.
- Queued-message cutoff uses the persisted update start; clock skew is negligible
  on one host.

## Progress log

| Date | Slice | Result |
|---|---|---|
| 2026-10-29 | 1 | updater endpoint, tag policy, compose/ops network, tests; apply not implemented |
| 2026-10-29 | 2 | apply/report, stop/snapshot/rollback, tag override; live rollback test pending |
| 2026-10-29 | 3 | drain/block/POST/queued-batch cleanup; live drain test pending |
| 2026-10-29 | 4 | hardcoded versions, DSH_VERSION removed, setup-only update.sh, adapter ref stamp |
| 2026-10-29 | 5 | updater docs, README security/ops, test plan; release validation pending |
