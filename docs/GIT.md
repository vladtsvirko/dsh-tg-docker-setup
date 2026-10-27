# Repository access (git credentials)

The runtime is one container running as one uid. **Everyone you allow into a
workspace shares that workspace's git credentials**, and the agent can read
everything under `/run/secrets`. This is the trust model: if you add someone to
the group and `ALLOWED_USER_IDS`, you are letting them commit with the workspace
credentials. There is no per-user isolation inside one container — see
[Security](#security) at the end.

What you get:

- a **default** profile for every workspace;
- optional **per-workspace** overrides (keyed by the directory name under
  `/data/workspace`);
- HTTPS tokens **or** SSH keys, for GitHub, GitLab, Gitea/Forgejo and any
  self-hosted host;
- per-profile commit identity (`user.name` / `user.email`).

The configuration is generated from one JSON manifest into
`/data/home/.dsh/git`; `/data/home/.gitconfig` only gains one `[include]` line.

## Files

```text
dsh-tg-docker-setup/
  secrets/                        # gitignored, mounted read-only at /run/secrets
    git/
      profiles.json               # the manifest
      github_pat.credentials      # optional token_file
      team_ed25519                # SSH key
      known_hosts
```

Compose already mounts it:

```yaml
volumes:
  - ./secrets:/run/secrets:ro
```

Create it from the example:

```sh
cp -r secrets.example secrets
chmod -R go-rwx secrets
$EDITOR secrets/git/profiles.json
```

The generator is part of the image, so after pulling this feature rebuild once:

```sh
docker compose build
docker compose up -d
```

After that, manifest changes need no rebuild — regenerate or restart (below).

## Manifest

```json
{
  "default": {
    "provider": "github",
    "auth": "https",
    "token": "github_pat_...",
    "identity": { "name": "Vlad", "email": "you@example.com" }
  },
  "projects": {
    "web-app": {
      "provider": "gitlab",
      "auth": "https",
      "host": "gitlab.example.com",
      "token": "glpat-...",
      "identity": { "name": "Vlad", "email": "you@work.example" }
    },
    "infra": {
      "provider": "gitea",
      "auth": "ssh",
      "host": "git.example.com",
      "key": "team_ed25519",
      "known_hosts": "known_hosts",
      "identity": { "name": "Vlad", "email": "you@example.com" }
    }
  }
}
```

- `default` applies to every repository, in every workspace.
- `projects` keys are **workspace directory names**. `/workspace new "Web App"`
  creates `/data/workspace/web-app`, so the key is `web-app`. An absolute path is
  also accepted.
- A project profile is **standalone**, not a partial override of `default`.
  Repeat the fields you need; use a shared `token_file` if you want one token in
  several projects.
- `token_file` is resolved relative to `secrets/git/`; `key` and `known_hosts`
  too (absolute paths work as well).

### Profile fields

| Field | Required | Meaning |
|---|---|---|
| `provider` | no, default `github` | `github`, `gitlab`, `gitea`, `forgejo`, `self-hosted` (alias `custom`) |
| `auth` | no, default `https` | `https` or `ssh` |
| `host` | for `gitea`, `forgejo`, `self-hosted` | defaults to `github.com` / `gitlab.com` |
| `username` | HTTPS: preset, self-hosted requires it | GitHub `x-access-token`, GitLab `oauth2`, Gitea `git` |
| `token` / `token_file` | HTTPS only | PAT; inline or a file next to the manifest |
| `key` | SSH only | private key path |
| `known_hosts` | SSH only | verified host keys; required |
| `identity.name` / `identity.email` | no | commit author inside that workspace |

## Providers

### GitHub — HTTPS token

Create a **fine-grained personal access token**: GitHub → Settings → Developer
settings → Fine-grained tokens. Repository access: the repos you need;
permissions: **Contents: Read and write**, **Metadata: Read**. A classic token
with `repo` also works.

```json
"default": {
  "provider": "github",
  "auth": "https",
  "token": "github_pat_...",
  "identity": { "name": "Vlad", "email": "you@example.com" }
}
```

Clone normally:

```sh
git clone https://github.com/you/private-repo.git
```

### GitHub — SSH deploy key

Per repository (read-only unless you enable write):

```sh
ssh-keygen -t ed25519 -C "dsh@nas" -f secrets/git/github_deploy -N ""
ssh-keyscan github.com > secrets/git/known_hosts
chmod 600 secrets/git/github_deploy secrets/git/known_hosts
cat secrets/git/github_deploy.pub
```

Add the public key under **Repository → Settings → Deploy keys** (tick *Allow
write access* if the agent must push). For many repos, use a machine user's SSH
key instead.

```json
"projects": {
  "web-app": {
    "provider": "github",
    "auth": "ssh",
    "host": "github.com",
    "key": "github_deploy",
    "known_hosts": "known_hosts"
  }
}
```

Clone with the SSH URL:

```sh
git clone git@github.com:you/private-repo.git
```

### GitLab — HTTPS token

Create a personal access token with `read_repository` and `write_repository`
(project/group access tokens work too).

```json
"projects": {
  "web-app": {
    "provider": "gitlab",
    "auth": "https",
    "host": "gitlab.com",
    "token": "glpat-...",
    "identity": { "name": "Vlad", "email": "you@example.com" }
  }
}
```

Self-managed GitLab: set `"host": "gitlab.example.com"`.

### GitLab — SSH key

Add the public key to GitLab → Preferences → SSH Keys, or as a deploy key on the
project:

```sh
ssh-keygen -t ed25519 -C "dsh@nas" -f secrets/git/gitlab_deploy -N ""
ssh-keyscan gitlab.com > secrets/git/known_hosts
```

```json
"projects": {
  "web-app": {
    "provider": "gitlab",
    "auth": "ssh",
    "host": "gitlab.com",
    "key": "gitlab_deploy",
    "known_hosts": "known_hosts"
  }
}
```

### Gitea / Forgejo

Generate a token in **Settings → Applications** with repository read/write
scope; user `git` works with the token as the password. `host` is required.

```json
"projects": {
  "infra": {
    "provider": "gitea",
    "auth": "https",
    "host": "git.example.com",
    "username": "git",
    "token": "..."
  }
}
```

SSH works the same as above with `"auth": "ssh"` and the key added to the Gitea
account or repo deploy keys.

### Self-hosted / generic

Use `self-hosted` (or `custom`) when the host is not one of the presets. HTTPS
requires an explicit `username`; SSH uses `git` unless you set one.

```json
"projects": {
  "legacy": {
    "provider": "self-hosted",
    "auth": "https",
    "host": "git.internal.example",
    "username": "vlad",
    "token": "..."
  }
}
```

## How it is applied

`/usr/local/bin/dsh-git-credentials` runs on every boot (and on `init` /
`reset-plugin`) if `/run/secrets/git/profiles.json` exists. It writes:

```text
/data/home/.dsh/git/
  gitconfig                       # default credential helper + includeIf blocks
  credentials/*.credentials       # HTTPS store files, mode 600
  projects/*.gitconfig            # per-workspace helper/ssh/identity
```

and appends one include to `/data/home/.gitconfig`:

```ini
[include]
    path = /data/home/.dsh/git/gitconfig
```

`includeIf "gitdir:/data/workspace/<project>/"` selects the project profile for
every repository under that directory, including clones and submodules. Generated
files are rebuilt from scratch on every run; do not edit them.

Regenerate after a manifest change (no restart, no rebuild):

```sh
docker compose exec dsh /usr/local/bin/dsh-git-credentials
```

A restart does the same thing. If generation fails, the entrypoint warns and the
runtime still boots; the last good files stay in place.

## Verify

```sh
# what applies in the container
docker compose exec dsh git config --global --get credential.helper
docker compose exec dsh git config --global --get-all include.path

# what applies inside a workspace
docker compose exec dsh sh -lc 'cd /data/workspace/web-app && git config --show-origin --get-all credential.helper'

# a real read against a private repository
docker compose exec dsh sh -lc 'cd /data/workspace/web-app && git ls-remote https://github.com/you/private-repo.git'
docker compose exec dsh sh -lc 'cd /data/workspace/web-app && git ls-remote git@github.com:you/private-repo.git'
```

Avoid `git credential fill` in shared logs: it prints the token.

## Rotate

1. Edit `secrets/git/profiles.json` (or the token/key file).
2. `docker compose exec dsh /usr/local/bin/dsh-git-credentials`
3. Verify with `git ls-remote`.
4. Revoke the old token/key at the provider.

No image rebuild and no container restart are required for a credential change.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `git credentials: profile "x": ...` in boot logs | manifest validation failed; the message names the field |
| `could not read Username for 'https://…'` | no helper for that host: project key does not match the workspace directory, or the profile is not under `default` |
| `Permission denied (publickey)` | key not added to the provider, wrong key, or a passphrase-protected key (BatchMode cannot prompt) |
| `Host key verification failed` | `known_hosts` missing or stale; regenerate with `ssh-keyscan host > secrets/git/known_hosts` and regenerate |
| `Repository not found` | token lacks access to that repo/org, or the SSH key is not a deploy key there |
| `403` on push | read-only token/deploy key; grant write |
| `detected dubious ownership` | `/data/workspace` is not owned by the container uid; run the `init` service (or `chown`) |
| `warning: … readable by group/others` | `chmod 600 secrets/git/<key>` |
| project credentials ignored | project key is the **directory** name; check `git config --show-origin` inside that directory |

SSH keys with passphrases are not supported by the generator (non-interactive
`BatchMode`). Use a passphrase-less deploy key, or mount an `ssh-agent` socket and
set `SSH_AUTH_SOCK` yourself.

## Security

- **One workspace, one credential set.** Anyone allowed into the group and
  `ALLOWED_USER_IDS` can use it, deliberately. Per-user restrictions are not
  enforced inside one container.
- The agent runs with `danger-full-access` in the container and can read
  `/run/secrets`. Treat every allowed user as having the credentials.
- Prefer least privilege: fine-grained token per provider/org, read-only deploy
  keys where pushes are not needed.
- Tokens belong in `secrets/`, not `.env`; environment variables are visible in
  `/proc` and easier to leak into logs.
- `secrets/` is gitignored. Back it up separately (encrypted) and never commit
  it; `data/` backups do not contain these files.
- Host keys are verified (`StrictHostKeyChecking=yes`); do not disable it.
