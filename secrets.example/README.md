# secrets/ (example)

Copy this directory and fill it in:

```sh
cp -r secrets.example secrets
chmod -R go-rwx secrets
$EDITOR secrets/git/profiles.json
```

`secrets/` is gitignored and read by the runtime from
`<dir>/secrets/git` (`DSH_GIT_SECRETS`); `dsh-git-credentials.mjs` regenerates
git config from `secrets/git/profiles.json` on every boot.

Never commit real tokens or keys. `default` is one account for every host;
`hosts` holds host-scoped accounts (one per forge), and `projects` overrides
both per workspace. See `docs/GIT.md` for GitHub, GitLab, Gitea, self-hosted,
HTTPS and SSH recipes.
