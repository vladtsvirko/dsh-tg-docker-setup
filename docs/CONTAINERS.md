# Containers

The setup uses **Podman only**. Docker is not installed, no docker group exists,
and nothing talks to a Docker socket.

```text
dsh (uid 995)
└─ podman (rootless)          the agent's disposable test containers
   └─ user namespace           container root = host dsh

root
└─ podman-compose             the optional Penpot stack
```

## The agent

`--containers podman` (the default) installs Podman, `uidmap`,
`slirp4netns`/`passt` and `fuse-overlayfs`, and gives `dsh` a subordinate id
range. The runtime unit stays fully hardened; no `SupplementaryGroups` is added.

```sh
# the service user's home is /srv/dsh/data/home; a manual sudo needs the runtime dir
sudo -u dsh env XDG_RUNTIME_DIR=/run/user/995 \
  podman run --rm docker.io/library/alpine:3 sh -c 'echo hello'
podman run --rm --memory 512m --cpus 1 docker.io/library/postgres:15 --version
podman ps -a
podman rm -f <id>
podman system prune -f
```

- Use **fully qualified images** (`docker.io/...`); short names may prompt for a
  registry, which fails in a non-interactive agent shell.
- Rootless Podman cannot bind ports below 1024. Use a high port and publish it
  on `127.0.0.1` for a test.
- Mount only what the test needs, and only paths owned by `dsh` (for example
  under `/srv/dsh/data/workspace`).
- Storage lives under `/srv/dsh/data/home/.local/share/containers`; it is part
  of the data backup and can grow. `podman system prune` is the cleanup.
- Containers share the host kernel. This is isolation, not a VM.

`podman-compose` is installed only when Penpot is selected; for a one-off
compose file use `podman-compose` after installing it yourself, or plain
`podman run`.

## Host prerequisites

The installer adds the pieces rootless Podman needs:

- `uidmap` (`newuidmap`/`newgidmap`) and a subordinate id range for `dsh`
  (`/etc/subuid`, `/etc/subgid`);
- `netavark` + `aardvark-dns` — without the DNS binary, containers start but
  cannot resolve each other, so a compose stack (Penpot) never becomes healthy;
- `passt` (the `pasta` binary) and `slirp4netns` for rootless networking, plus `fuse-overlayfs` for builds;
- `loginctl enable-linger dsh`, so rootless Podman gets a systemd user manager and cgroup.

On Ubuntu 24.04+ the kernel may restrict unprivileged user namespaces
(`kernel.apparmor_restrict_unprivileged_userns=1`). Rootless Podman then fails
with `newuidmap: write to uid_map failed: Operation not permitted`. Either load
the shipped `/etc/apparmor.d/podman` profile or relax the restriction:

```sh
echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/99-podman-userns.conf
sudo sysctl --system
```

That weakens a kernel mitigation; do it only if you need rootless containers on
that host.

### ufw

Podman does not insert ufw rules like Docker. If ufw is active, the design
component adds `allow in on <podman bridge>`, `route allow` on the same bridge,
a route from the LAN interface into the bridge (published ports are DNAT'd and
hit the forward policy, not INPUT), and the Penpot port from the LAN. Without
the bridge rules, containers cannot
resolve each other (`host not found in upstream`), which looks like a DNS bug
but is the firewall.

## Penpot

`--design penpot` runs the design stack through **rootful** `podman-compose`
under the updater. The Penpot images need normal container networking and
bind-mounted data; the agent's own containers remain rootless.

```sh
cd /srv/dsh/design
podman-compose -f compose.yaml ps
podman-compose -f compose.yaml down      # data stays in design/data/
```

The stack is controlled from the bot with `/components` (Enable /
Disable / Port); `setup.sh components enable|disable|configure design …` is the
host equivalent. Neither restarts DSH; the Penpot tools load on the next
runtime start.

## Why not Docker

The Docker socket is root-equivalent: any process that can reach it can ask
dockerd to mount the host filesystem. Rootless Podman gives the agent containers
without that capability, and the unit's `ProtectSystem`/`ProtectHome` remain
meaningful for the runtime process.
