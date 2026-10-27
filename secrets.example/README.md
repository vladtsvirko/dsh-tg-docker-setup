# secrets/ (example)

Copy this directory and fill it in:

```sh
cp -r secrets.example secrets
chmod -R go-rwx secrets
$EDITOR secrets/git/profiles.json
```

`secrets/` is gitignored and mounted read-only at `/run/secrets`; `git-credentials`
regenerates git config from `secrets/git/profiles.json` on every boot.

Never commit real tokens or keys. See `docs/GIT.md` for GitHub, GitLab, Gitea and
self-hosted recipes.
