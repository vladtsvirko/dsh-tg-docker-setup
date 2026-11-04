#!/usr/bin/env node
/**
 * Build or merge `secrets/git/profiles.json` from installer answers.
 *
 * The installer collects one or more accounts (a provider, an auth method and
 * the secret) and pipes them here as a JSON array on stdin. One account becomes
 * `default` (the historical shape, still what a single-token deployment gets);
 * two or more become `hosts` entries, each scoped to its host so a token for
 * one forge is never offered to another. `--merge` keeps the existing file and
 * only replaces the hosts it is given, which is how a repair adds a second
 * account without losing the first.
 *
 * Usage:
 *   node scripts/git-manifest.mjs --file <path> [--merge] [--name N --email E] < accounts.json
 */
import { chmod, mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'

const PRESETS = { github: 'github.com', gitlab: 'gitlab.com' }
const PROVIDERS = new Set(['github', 'gitlab', 'gitea', 'forgejo', 'self-hosted', 'custom'])

const fail = (message) => {
  console.error(`git manifest: ${message}`)
  process.exit(1)
}

const text = (value, field) => {
  if (typeof value !== 'string' || value.trim().length === 0) fail(`"${field}" must be a non-empty string`)
  return value.trim()
}

function parseArgs(argv) {
  const options = { file: undefined, merge: false, name: undefined, email: undefined }
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    if (arg === '--file') options.file = argv[++index]
    else if (arg === '--merge') options.merge = true
    else if (arg === '--name') options.name = argv[++index]
    else if (arg === '--email') options.email = argv[++index]
    else fail(`unknown argument ${arg}`)
  }
  if (options.file === undefined) fail('--file is required')
  return options
}

/** Resolve one installer answer into a manifest entry, or explain why not. */
function normalize(raw, identity) {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) fail('each account must be an object')
  const provider = (raw.provider === undefined ? 'github' : text(raw.provider, 'provider')).toLowerCase()
  if (!PROVIDERS.has(provider)) fail(`unknown provider "${provider}"`)

  const auth = (raw.auth === undefined ? 'https' : text(raw.auth, 'auth')).toLowerCase()
  if (auth !== 'https' && auth !== 'ssh') fail(`account ${provider}: "auth" must be "https" or "ssh"`)

  const host = raw.host === undefined ? PRESETS[provider] : text(raw.host, 'host')
  if (host === undefined) fail(`provider "${provider}" needs a host`)

  const entry = { provider, host, auth }
  if (auth === 'https') {
    entry.token = text(raw.token, 'token')
  } else {
    entry.key = text(raw.key, 'key')
    entry.known_hosts = text(raw.known_hosts, 'known_hosts')
  }
  if (identity !== undefined) entry.identity = identity
  return entry
}

const hostOf = (entry) => (entry.host === undefined ? PRESETS[String(entry.provider).toLowerCase()] : entry.host)

async function readExisting(file, merge) {
  if (!merge) return { projects: {} }
  try {
    const parsed = JSON.parse(await readFile(file, 'utf8'))
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) fail(`${file} is not a JSON object`)
    return parsed
  } catch (error) {
    if (error.code === 'ENOENT') return { projects: {} }
    fail(`cannot read the existing manifest: ${error instanceof Error ? error.message : String(error)}`)
  }
}

const options = parseArgs(process.argv.slice(2))

let raw = ''
for await (const chunk of process.stdin) raw += chunk
let accounts
try {
  accounts = JSON.parse(raw.length === 0 ? '[]' : raw)
} catch (error) {
  fail(`stdin is not JSON: ${error instanceof Error ? error.message : String(error)}`)
}
if (!Array.isArray(accounts) || accounts.length === 0) fail('no accounts were given')

const identity = options.name !== undefined && options.email !== undefined
  ? { name: text(options.name, 'name'), email: text(options.email, 'email') }
  : undefined
const entries = accounts.map((account) => normalize(account, identity))

const manifest = await readExisting(options.file, options.merge)
if (manifest.projects === undefined) manifest.projects = {}

if (!options.merge && entries.length === 1) {
  // The historical shape: one account is the default for every host. The
  // generated credential store is host-scoped, so this does not leak the token
  // to another forge.
  manifest.default = entries[0]
} else {
  if (manifest.hosts === undefined) manifest.hosts = {}
  if (manifest.hosts === null || typeof manifest.hosts !== 'object' || Array.isArray(manifest.hosts)) {
    fail('"hosts" in the existing manifest is not an object')
  }
  for (const entry of entries) {
    // A single account already in `default` is promoted in place when the new
    // account is for the same host; otherwise it stays as the global fallback.
    if (manifest.default !== undefined && hostOf(manifest.default) === entry.host) {
      manifest.default = entry
      continue
    }
    manifest.hosts[entry.host] = entry
  }
}

const output = `${JSON.stringify(manifest, null, 2)}\n`
const temporary = `${options.file}.tmp`
await mkdir(dirname(options.file), { recursive: true, mode: 0o700 })
await writeFile(temporary, output, { mode: 0o600 })
await rename(temporary, options.file)
await chmod(options.file, 0o600)

const labels = []
if (manifest.default !== undefined) labels.push(`default=${manifest.default.provider}/${manifest.default.auth}`)
for (const [host, entry] of Object.entries(manifest.hosts ?? {})) {
  labels.push(`${host}=${entry.provider}/${entry.auth}`)
}
console.log(labels.join(', '))
