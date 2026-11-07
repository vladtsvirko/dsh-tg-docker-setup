# Upstream watch: is there a new DSH release candidate?

A scheduled task answers one question every day: **is our pinned DSH older than
the newest release candidate, and what would upgrading cost?** It ends with an
upgrade plan and a short list of decisions for a human — never with an upgrade.

| | |
|---|---|
| Schedule | daily 08:00 Europe/Minsk, DSH session schedule (id `schedule-e995eea8`) |
| Pinned version | `VERSION` — the prefix before the last `-<major>.<minor>.<patch>` is the DSH part |
| Installed by | `setup.sh` / `setup.sh update` as `@deepseek-ai/dsh@<DSH part>` |
| Report | the chat message with the upgrade plan; no files are written |
| No-op | pinned == newest RC → say so in one line, write nothing |

`VERSION` is `<dsh>-<product>`: for `0.2.1-rc.5-0.14.1` the DSH part is
`0.2.1-rc.5`. `setup.sh` installs exactly that version; there is no separate
pin.

If the schedule is lost (session reset, new host), recreate it from this page:
steps 1–6 are the prompt, the *Rules* and *What counts as a real decision*
sections are the constraints.

## Rules

- Read-only: use a scratch directory under `/tmp` and do not modify the
  checkout. Never rebuild, never tag, never edit `VERSION` — the release is a
  human decision (see the checklist in `AGENTS.md`).
- Report what the evidence says. If a release has no feature worth acting on,
  say that; if there is no real decision to make, list none.
- Distinguish *tested* from *declared*: the connector's peer range is the
  contract, the compatibility matrix is what we actually ran.
- Alpha tags are context, not targets. Only `-rc.` (or stable) releases are in
  scope.

## Procedure

### 1. Resolve versions

```sh
npm view @deepseek-ai/dsh dist-tags --json          # latest / next / alpha
npm view @deepseek-ai/dsh versions --json           # pick the highest "-rc."
cat VERSION                                         # what we run: <dsh>-<product>
```

`latest` and `next` normally point at the same RC; `alpha` is the next line.
Ignore build metadata, compare semver order.

### 2. If pinned == newest RC

Reply with one line — "no new RC; still `X` (checked <date>)" — and stop. Do not
invent a report.

### 3. Collect the change surface

```sh
# release notes, newest first (bodies are bilingual: read the English block)
curl -s "https://api.github.com/repos/deepseek-ai/deepseek-harness/releases?per_page=15"

# per-release file diff, grouped by package (GitHub caps the file list at 300;
# use the tree diff below for completeness)
curl -s "https://api.github.com/repos/deepseek-ai/deepseek-harness/compare/dsh-v<pinned>...dsh-v<target>"
```

Prefer the tree diff, which is complete:

```sh
# 1 = not truncated; diff the sha maps to list added/changed/removed paths
curl -s "https://api.github.com/repos/deepseek-ai/deepseek-harness/git/trees/dsh-v<pinned>?recursive=1"
curl -s "https://api.github.com/repos/deepseek-ai/deepseek-harness/git/trees/dsh-v<target>?recursive=1"
```

Group changed paths by `packages/<group>/<package>` and `apps/<app>`; a change
under `snapshots/`, `*.spec.ts`, `docs/`, or `.agents/notes` is not a runtime
change.

### 4. Check the official migration guides

```sh
# one directory per incompatibility, authored by upstream
curl -s "https://api.github.com/repos/deepseek-ai/deepseek-harness/contents/docs/upgrade-guide?ref=dsh-v<target>"
```

Read every guide whose directory is `v<target>` or between the two versions.
Each has a `Change` and a `Migration` section; quote the ones that touch what we
ship.

### 5. Check the contract packages (the only verdict that matters)

These are what this setup and the connector actually bind to. Byte-compare the
published packages rather than reading source diffs:

```sh
work=$(mktemp -d); cd "$work"
for p in dsh dsh-agent dsh-llm dsh-session dsh-plugin-manager dsh-app-boot \
         dsh-base dsh-client-ui-cordis; do
  for v in <pinned> <target>; do
    curl -sf -o "$p-$v.tgz" "https://registry.npmjs.org/@deepseek-ai/$p/-/$p-$v.tgz"
    mkdir -p "$p-$v" && tar -xzf "$p-$v.tgz" -C "$p-$v" --strip-components=1
  done
  diff -rq "$p-<pinned>" "$p-<target>" | grep -v package.json
done
```

Empty output for a package means the contract is untouched. To measure the whole
runtime, compare every installed `@deepseek-ai/dsh-*` package against its
published tarball (as of 2026-11-03: 24 of 294 packages changed between rc.2 and
rc.5 — client UI, `llm-deepseek*`, `mcp-*`, `web-app`/`web-frontend`).

Also check, by reading the two manifests:

- connector `peerDependencies` and penpot's — do they still admit the target?
  The loader evaluates ranges with `includePrerelease: true`, so `0.2.1-rc.5`
  satisfies `>=0.1.0-rc.6 <0.3.0-0`.
- profile config we write (`provider`, `model`, plugin blocks): any removed or
  renamed key in `docs/config-catalog.md` that we set?
- `dsh --version` output shape (the entrypoint parses it) and that
  `dsh plugin allow-version` / `version-exemptions` still exist:
  `npx -y @deepseek-ai/dsh@<target> plugin --profile <tmp> version-exemptions`.

### 6. Report the plan

Post the answer in the chat, using this skeleton:

1. **Snapshot** — pinned vs target, dates, `dist-tags`, releases in range.
2. **What ships** — table of user-visible changes and whether they touch us.
3. **Compatibility findings** — verdict first, then the evidence table, then
   residual risks. Separate *breaks* from *annoyances* from *needs UAT*.
4. **Upgrade plan** — setup tag → `setup.sh` / `setup.sh update` → plugin floors in
   `plugins.json` → checks → rollback, using the release checklist in
   `AGENTS.md`.
5. **Decisions needed** — only real forks: product scope, model route, policy.
   Each with cost of each option and a recommendation. If there are none, say so.
6. **Open items for UAT** — what a human should click, derived from the diff.

Then summarise in chat: verdict, the plan in five lines, and the decisions with
their options.

## What counts as a real decision

Something where both options are defensible and the choice changes the product —
for example: take this RC now or wait for the next line; follow DeepSeek's
published model list or freeze the catalog. Not: "bump the version" (mandated),
"re-run tests" (mandated), or anything the release checklist already decides.
