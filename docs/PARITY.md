# Native and Docker: one product, two isolations

The setup ships two ways to run the same runtime. This page is the contract
between them, so a feature cannot quietly work in one and not the other.

```
                 native                         docker
host             systemd units                  compose stack
runtime          unprivileged `dsh` user         unprivileged user in a container
agent sees       the host filesystem            only /data (and /run/secrets)
privilege        none beyond the service user   none inside; the updater is the only
                                                member of the docker group
control          Telegram + the web UI          Telegram + the web UI
data             /srv/dsh/data                  ./data (bind-mounted at /data)
updater          dsh-updater.service (127.0.0.1)  updater sidecar (ops network)
```

**The rule is native-first.** A capability is designed against the native
deployment, because that is where the least is automated for us: no image
rebuild, no fresh filesystem, an operator's existing service user, a real
firewall. Docker may then make it safer (a smaller blast radius) — never
smaller. When the two disagree, native wins and Docker adapts.

## What is identical by construction

Both modes run the **same** `entrypoint.sh` and `supervisor.mjs`, mount the same
data layout, and are configured by the same `.env` keys:

| Concern | Mechanism (both modes) |
|---|---|
| Profile, plugin install, provider route | `entrypoint.sh` (same file) |
| Restarts, trials, rollback, control socket | `supervisor.mjs` (loopback, bearer token) |
| Update, health gate, rollback, version policy | `update.sh --self[-to]` (same file) |
| Health check | `scripts/repair.sh` — `install.sh --doctor`, `update.sh --doctor` |
| Telegram connector and its commands | the same plugin, installed from the same tag |
| One runtime per data directory | `data/.runtime.lock` + `data/.runtime.json` |
| Secrets | `.env` (0600/0640), `secrets/git/`, `.credentials.yaml` (0600) |

The data layout is the same directory tree, so a deployment can be moved between
modes by pointing `--dir` at it (data is not converted, and the other mode is
stopped first).

Not every key is shared: `DSH_CPUS`, `DSH_MEM_LIMIT`, `DSH_DOCKER_GID` and
`pids_limit` are compose-only (native has no cgroup wrapper; hardening comes from
the systemd unit), and the native unit pins `DSH_PERMISSION_MODE` itself. Both
modes read the same `.env`, but a compose-only key is simply ignored natively.

## What is intentionally different

| Area | Native | Docker | Why |
|---|---|---|---|
| Isolation | none below the service user | container, read-only rootfs, dropped caps | the container *is* the boundary |
| Host access | the agent can read the host | only `/data` and `secrets/` | the trade Docker buys |
| Firewall | ufw gates the port; `/firewall` advises | ufw never sees a published port | Docker DNATs before INPUT |
| Updates | checkout + `npm i -g dsh` + restart | rebuild the image | same script, different apply step |
| Runtime install | Node ≥ 22 on the host | baked into the image | |
| Updater | root, `127.0.0.1:8787` | sidecar, `ops` network | both privileged, neither exposed |
| Tiers | `sandbox` (systemd hardening) or `privileged` (docker group) | n/a | native has host policy to choose |

Everything in that table is a difference in *isolation*, not in *features*: the
commands, the restart semantics, the diagnostics and the update flow are the
same, and every one of them is exercised natively.

## Android/phone and browser use

Both modes are reached the same way: `http://<bind>:<port>/` with the signed
`?token=` link (`/web` in Telegram prints it). A native host-only install
(`127.0.0.1`) needs the SSH tunnel the plan prints; Docker with
`DSH_BIND_IP=127.0.0.1` needs the same. A LAN bind is the same exposure in both,
and both print the warning.

## The guard that makes a restart enough

A restart releases the runtime's session handles only if no *other* process is
using the same data directory. Two runtimes there (a native service beside a
Docker stack, two containers from two checkouts) corrupt the store, share a bot
token, and hold each other's session write handles: the web UI of one shows a
stale workspace list while the other's Telegram answers "held by another
client", and restarting either changes nothing.

Both modes now take a kernel lock on `data/.runtime.lock` at boot and refuse to
be the second runtime, naming the holder from `data/.runtime.json`. `--doctor`
reports a live marker from a different mode as a failure. That is why a restart
on a correctly deployed host is a complete recovery again.

## Adding a feature

1. Write it against the native deployment first: it must work with Node on the
   host, `systemctl` for lifecycle, and the doctor for diagnosis.
2. Docker gets the same code path through `entrypoint.sh` / `update.sh`; the
   only Docker-specific part may be *how* the process is started or stopped.
3. If a behaviour is only possible with the container boundary, write it down in
   this table — and check that native is at least told why it does not apply.
