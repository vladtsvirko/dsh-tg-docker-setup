#!/usr/bin/env node
/**
 * Set the GitHub topics that make a plugin repository discoverable.
 *
 * The upstream DSH README asks plugin repositories to carry the `dsh-plugin`
 * topic. Topics are repository metadata (the About box), so they need an API
 * token with repository administration permission; the runtime's normal
 * git-push token usually does not have it.
 *
 *   node scripts/github-topics.mjs --check
 *   GITHUB_TOKEN=... node scripts/github-topics.mjs
 *
 * `--check` needs no token: reading public topics is unauthenticated.
 */
const TARGETS = {
  'vladtsvirko/dsh-telegram-connector': ['dsh-plugin', 'deepseek-harness', 'telegram', 'cordis', 'ai-agent'],
  'vladtsvirko/dsh-penpot-plugin': ['dsh-plugin', 'deepseek-harness', 'penpot', 'design', 'cordis'],
}

const args = new Set(process.argv.slice(2))
const check = args.has('--check')
const token = process.env.GITHUB_TOKEN ?? process.env.GH_TOKEN ?? ''
const headers = {
  accept: 'application/vnd.github+json',
  'user-agent': 'dsh-tg-docker-setup',
  ...(token.length === 0 ? {} : { authorization: `Bearer ${token}` }),
}

const fail = (message) => {
  console.error(`github-topics: ${message}`)
  process.exit(1)
}

if (!check && token.length === 0) {
  fail('set GITHUB_TOKEN (or GH_TOKEN) to a token with repository administration permission')
}

let failed = false
for (const [repo, desired] of Object.entries(TARGETS)) {
  const response = await fetch(`https://api.github.com/repos/${repo}/topics`, { headers })
  const body = await response.json().catch(() => ({}))
  if (!response.ok) {
    console.error(`${repo}: cannot read topics (${String(response.status)}) ${body.message ?? ''}`)
    failed = true
    continue
  }
  const current = Array.isArray(body.names) ? body.names : []
  const missing = desired.filter((name) => !current.includes(name))
  if (check) {
    console.log(`${repo}: ${current.length === 0 ? '(none)' : current.join(', ')}${missing.length === 0 ? '' : ` — missing ${missing.join(', ')}`}`)
    if (missing.length > 0) failed = true
    continue
  }
  const updated = await fetch(`https://api.github.com/repos/${repo}/topics`, {
    method: 'PUT',
    headers: { ...headers, 'content-type': 'application/json' },
    body: JSON.stringify({ names: desired }),
  })
  const result = await updated.json().catch(() => ({}))
  if (!updated.ok) {
    console.error(`${repo}: cannot set topics (${String(updated.status)}) ${result.message ?? ''}`)
    if (updated.status === 403) {
      console.error('  the token lacks repository administration; use the GitHub UI or an admin-scoped token')
    }
    failed = true
    continue
  }
  console.log(`${repo}: ${Array.isArray(result.names) ? result.names.join(', ') : desired.join(', ')}`)
}

process.exit(failed ? 1 : 0)
