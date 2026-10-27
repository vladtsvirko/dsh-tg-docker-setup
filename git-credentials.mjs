#!/usr/bin/env node
/**
 * Turn secrets/git/profiles.json into git configuration.
 *
 * The contract is one manifest with an optional `default` profile and optional
 * per-workspace `projects`. Every profile is either HTTPS (credential store
 * file) or SSH (core.sshCommand with an explicit key and known_hosts).
 *
 * Generated files live under $HOME/.dsh/git; $HOME/.gitconfig only gains one
 * [include] line. Re-running is safe: the generated directory is rebuilt and
 * the include is not duplicated.
 *
 * Everyone allowed in a workspace shares its credentials. This is a
 * configuration layer, not an isolation boundary; see docs/GIT.md.
 */
import { existsSync, realpathSync } from 'node:fs'
import { chmod, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { dirname, isAbsolute, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const PRESETS = {
  github: { host: 'github.com', httpsUser: 'x-access-token', sshUser: 'git' },
  gitlab: { host: 'gitlab.com', httpsUser: 'oauth2', sshUser: 'git' },
  gitea: { host: undefined, httpsUser: 'git', sshUser: 'git' },
  forgejo: { host: undefined, httpsUser: 'git', sshUser: 'git' },
  'self-hosted': { host: undefined, httpsUser: undefined, sshUser: 'git' },
  custom: { host: undefined, httpsUser: undefined, sshUser: 'git' },
}

const fail = (message) => {
  throw new Error(message)
}

const text = (value, field) => {
  if (typeof value !== 'string' || value.trim().length === 0) fail(`"${field}" must be a non-empty string`)
  return value.trim()
}

const optionalText = (value, field) => {
  if (value === undefined) return undefined
  return text(value, field)
}

/** Escape a value for a gitconfig line. */
const escapeValue = (value) => value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/[\r\n]/g, ' ')

/** Quote a shell argument inside core.sshCommand / credential helper. */
const shellQuote = (value) => (/^[A-Za-z0-9_./:@%+=,-]+$/.test(value) ? value : `"${value.replace(/["\\$`]/g, '\\$&')}"`)

const isInside = (root, candidate) => {
  const rel = relative(resolve(root), resolve(candidate))
  return rel === '' || (!rel.startsWith('..') && !isAbsolute(rel))
}

const projectPath = (key, workspaceRoot) => {
  const trimmed = key.trim()
  if (trimmed.length === 0) fail('project keys must not be empty')
  const path = isAbsolute(trimmed) ? resolve(trimmed) : resolve(workspaceRoot, trimmed)
  if (!isAbsolute(trimmed) && !isInside(workspaceRoot, path)) {
    fail(`project "${key}" escapes the workspace root (${workspaceRoot})`)
  }
  // Git matches includeIf against the real path of the repository; resolve the
  // workspace directory when it already exists (it does after /workspace new).
  return existsSync(path) ? realpathSync(path) : path
}

const safeName = (key, index) => {
  const cleaned = key.replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'project'
  return `${String(index).padStart(2, '0')}-${cleaned}`
}

const resolveFile = (value, secretsDir, field) => {
  const path = isAbsolute(value) ? value : resolve(secretsDir, value)
  return path
}

async function resolveProfile(label, entry, { secretsDir }) {
  if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
    fail(`profile "${label}" must be an object`)
  }

  const provider = (optionalText(entry.provider, `${label}.provider`) ?? 'github').toLowerCase()
  const preset = PRESETS[provider]
  if (preset === undefined) {
    fail(`profile "${label}": unknown provider "${provider}" (use github, gitlab, gitea, forgejo, self-hosted)`)
  }

  const auth = (optionalText(entry.auth, `${label}.auth`) ?? 'https').toLowerCase()
  if (auth !== 'https' && auth !== 'ssh') fail(`profile "${label}": "auth" must be "https" or "ssh"`)

  const host = optionalText(entry.host, `${label}.host`) ?? preset.host
  if (host === undefined) fail(`profile "${label}": provider "${provider}" needs "host"`)

  const identity = entry.identity
  if (identity !== undefined) {
    if (identity === null || typeof identity !== 'object') fail(`profile "${label}": "identity" must be an object`)
    optionalText(identity.name, `${label}.identity.name`)
    optionalText(identity.email, `${label}.identity.email`)
  }

  if (auth === 'https') {
    const username = optionalText(entry.username, `${label}.username`) ?? preset.httpsUser
    if (username === undefined) fail(`profile "${label}": HTTPS needs "username" for provider "${provider}"`)
    let token = optionalText(entry.token, `${label}.token`)
    if (token === undefined && entry.token_file !== undefined) {
      const path = resolveFile(text(entry.token_file, `${label}.token_file`), secretsDir, `${label}.token_file`)
      token = (await readFile(path, 'utf8')).trim()
      if (token.length === 0) fail(`profile "${label}": token file ${path} is empty`)
    }
    if (token === undefined) fail(`profile "${label}": HTTPS needs "token" or "token_file"`)
    return { label, provider, auth, host, username, token, identity }
  }

  const key = resolveFile(text(entry.key, `${label}.key`), secretsDir, `${label}.key`)
  const knownHosts = resolveFile(text(entry.known_hosts, `${label}.known_hosts`), secretsDir, `${label}.known_hosts`)
  for (const [path, field] of [[key, 'key'], [knownHosts, 'known_hosts']]) {
    try {
      const info = await stat(path)
      if (!info.isFile()) fail(`profile "${label}": ${field} ${path} is not a file`)
      if (field === 'key' && (info.mode & 0o077) !== 0) {
        console.error(`git credentials: warning: ${path} is readable by group/others; chmod 600 it`)
      }
    } catch (error) {
      if (error instanceof Error && error.message.startsWith(`profile`)) throw error
      fail(`profile "${label}": cannot read ${field} ${path}: ${error.message}`)
    }
  }
  const username = optionalText(entry.username, `${label}.username`) ?? preset.sshUser
  return { label, provider, auth, host, username, key, knownHosts, identity }
}

function profileConfig(profile, { outputDir, prefix }) {
  const files = new Map()
  const lines = [`# generated by dsh-git-credentials for ${profile.label}`, '']

  if (profile.auth === 'https') {
    const credentials = `credentials/${prefix}.credentials`
    const url = `https://${encodeURIComponent(profile.username)}:${encodeURIComponent(profile.token)}@${profile.host}`
    files.set(credentials, `${url}\n`)
    // Reset the list first: an included project profile must win over the
    // default helper even when both cover the same host.
    lines.push('[credential]', '\thelper =', `\thelper = store --file=${shellQuote(join(outputDir, credentials))}`, '')
  } else {
    const ssh = [
      'ssh',
      '-i', shellQuote(profile.key),
      '-o', 'IdentitiesOnly=yes',
      '-o', 'BatchMode=yes',
      '-o', 'StrictHostKeyChecking=yes',
      '-o', `UserKnownHostsFile=${shellQuote(profile.knownHosts)}`,
    ].join(' ')
    lines.push('[core]', `\tsshCommand = ${ssh}`, '')
  }

  if (profile.identity !== undefined) {
    lines.push('[user]')
    if (profile.identity.name !== undefined) lines.push(`\tname = ${escapeValue(profile.identity.name)}`)
    if (profile.identity.email !== undefined) lines.push(`\temail = ${escapeValue(profile.identity.email)}`)
    lines.push('')
  }

  return { config: `${lines.join('\n').trimEnd()}\n`, files }
}

/**
 * Pure-ish: reads token/key files, returns the files to write plus the include
 * line. `apply` performs the writes.
 */
export async function render(manifest, options) {
  if (manifest === null || typeof manifest !== 'object' || Array.isArray(manifest)) {
    fail('profiles.json must be a JSON object')
  }

  const secretsDir = resolve(options.secretsDir)
  const workspaceRoot = resolve(options.workspaceRoot)
  const outputDir = resolve(options.outputDir)
  const files = new Map()
  const base = ['# generated by dsh-git-credentials; edit profiles.json instead', '']
  const summary = []

  if (manifest.default !== undefined) {
    const profile = await resolveProfile('default', manifest.default, { secretsDir })
    const { config, files: generated } = profileConfig(profile, { outputDir, prefix: 'default' })
    for (const [name, content] of generated) files.set(name, content)
    base.push(config.trimEnd(), '')
    summary.push(`default=${profile.provider}/${profile.auth}`)
  }

  const projects = manifest.projects ?? {}
  if (projects === null || typeof projects !== 'object' || Array.isArray(projects)) {
    fail('"projects" must be an object keyed by workspace directory name')
  }

  let index = 0
  for (const [key, entry] of Object.entries(projects)) {
    const path = projectPath(key, workspaceRoot)
    const profile = await resolveProfile(key, entry, { secretsDir })
    const prefix = safeName(key, index)
    index += 1
    const { config, files: generated } = profileConfig(profile, { outputDir, prefix })
    for (const [name, content] of generated) files.set(name, content)
    files.set(`projects/${prefix}.gitconfig`, config)
    base.push(
      `[includeIf "gitdir:${escapeValue(path.replace(/\/+$/, ''))}/"]`,
      `\tpath = ${shellQuote(join(outputDir, `projects/${prefix}.gitconfig`))}`,
      '',
    )
    summary.push(`${key}=${profile.provider}/${profile.auth}`)
  }

  return {
    files,
    config: `${base.join('\n').trimEnd()}\n`,
    includePath: join(outputDir, 'gitconfig'),
    summary,
  }
}

async function ensureInclude(homeDir, includePath) {
  const gitconfig = join(homeDir, '.gitconfig')
  let current = ''
  try {
    current = await readFile(gitconfig, 'utf8')
  } catch (error) {
    if (error.code !== 'ENOENT') throw error
  }

  if (current.includes(includePath)) return

  const block = `# dsh git credentials (managed by dsh-git-credentials)\n[include]\n\tpath = ${shellQuote(includePath)}\n`
  const next = current.trim().length === 0 ? block : `${current.trimEnd()}\n\n${block}`
  await mkdir(dirname(gitconfig), { recursive: true })
  await writeFile(gitconfig, next, { mode: 0o600 })
  await chmod(gitconfig, 0o600)
}

export async function apply(manifest, options) {
  const secretsDir = resolve(options.secretsDir)
  const workspaceRoot = resolve(options.workspaceRoot)
  const homeDir = resolve(options.homeDir)
  const outputDir = resolve(options.outputDir)

  if (outputDir === '/' || outputDir === homeDir || outputDir === workspaceRoot ||
      isInside(outputDir, homeDir) || isInside(outputDir, workspaceRoot)) {
    fail(`refusing to generate into ${outputDir}; choose a dedicated directory`)
  }

  const rendered = await render(manifest, { secretsDir, workspaceRoot, outputDir })

  await rm(outputDir, { recursive: true, force: true })
  await mkdir(join(outputDir, 'projects'), { recursive: true })
  await mkdir(join(outputDir, 'credentials'), { recursive: true })

  for (const [name, content] of rendered.files) {
    const path = join(outputDir, name)
    await mkdir(dirname(path), { recursive: true })
    await writeFile(path, content, { mode: 0o600 })
    await chmod(path, 0o600)
  }
  await writeFile(rendered.includePath, rendered.config, { mode: 0o600 })
  await chmod(rendered.includePath, 0o600)
  await ensureInclude(homeDir, rendered.includePath)

  return rendered.summary
}

// --- CLI ------------------------------------------------------------------

const isCli = process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)

if (isCli) {
  const secretsDir = process.env.DSH_GIT_SECRETS ?? '/run/secrets/git'
  const workspaceRoot = process.env.DSH_WORKSPACE ?? '/data/workspace'
  const homeDir = process.env.HOME ?? '/data/home'
  const outputDir = process.env.DSH_GIT_OUTPUT ?? join(homeDir, '.dsh', 'git')
  const manifestPath = join(secretsDir, 'profiles.json')

  try {
    const manifest = JSON.parse(await readFile(manifestPath, 'utf8'))
    const summary = await apply(manifest, { secretsDir, workspaceRoot, homeDir, outputDir })
    console.log(`git credentials: ${summary.length === 0 ? 'nothing configured' : summary.join(', ')}`)
  } catch (error) {
    console.error(`git credentials: ${error instanceof Error ? error.message : String(error)}`)
    process.exitCode = 1
  }
}
