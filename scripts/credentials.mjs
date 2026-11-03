#!/usr/bin/env node
/**
 * Read and repair the runtime's stored credentials, without printing them.
 *
 * The runtime resolves a provider API key in this order:
 *
 *   $DSH_HOME/.credentials.yaml  >  process environment  >  .env files
 *
 * The middle layer is what the installer writes (`OPENCODE_GO_API_KEY=` in the
 * deployment `.env`, which systemd or compose exports). So a key saved once
 * through the web UI's Models page keeps winning over every later `.env` edit:
 * a repair run writes the key the operator pasted, the runtime ignores it, and
 * model calls fail with the old credential. That is the "multiplied token" a
 * user sees — one key in `.env`, another one in the store, no way to tell which
 * is used.
 *
 * This helper is the small, auditable bridge: it reports whether the store holds
 * a value for a reference ("present", "match", "different", never the value) and
 * can make the deployment's `.env` win by writing the same value into the store,
 * or drop the stored entry so the environment applies again. Secret material
 * travels through the environment, never argv (argv is world-readable in `ps`),
 * and a rewrite goes through a temp file + rename at mode 0600.
 *
 * Usage (from scripts/repair.sh; run it directly only when debugging):
 *
 *   DSH_VALUE=… node credentials.mjs status --home <DSH_HOME> --ref OPENCODE_GO_API_KEY
 *   DSH_VALUE=… node credentials.mjs sync   --home <DSH_HOME> --ref OPENCODE_GO_API_KEY
 *              node credentials.mjs clear  --home <DSH_HOME> --ref OPENCODE_GO_API_KEY
 *
 * Exit codes: 0 ok, 1 usage/tooling error, 2 the document exists but cannot be
 * trusted (never rewritten).
 */

import { createRequire } from 'node:module'
import { chmod, mkdir, readFile, rename, stat, unlink, writeFile } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { dirname, join } from 'node:path'

const require = createRequire(import.meta.url)
const FILENAME = '.credentials.yaml'
const REF_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/

function fail(message, code = 1) {
  process.stderr.write(`credentials: ${message}\n`)
  process.exit(code)
}

/** Load the YAML library the runtime ships, from a global or local install. */
function loadYaml() {
  const candidates = [process.cwd(), join(process.cwd(), 'node_modules')]
  // The global dsh install carries `yaml` in its own node_modules; the host
  // does not need a separate dependency for this helper.
  for (const root of globalRoots()) candidates.push(join(root, 'node_modules'))
  for (const base of candidates) {
    try {
      return require(require.resolve('yaml', { paths: [base] }))
    } catch {
      /* try the next place */
    }
  }
  fail('the yaml package was not found (is dsh installed globally?)')
}

function globalRoots() {
  const roots = []
  if (process.env.DSH_GLOBAL_ROOT) roots.push(process.env.DSH_GLOBAL_ROOT)
  // npm root -g, without spawning npm: the dsh package lives there.
  for (const prefix of [process.env.npm_config_prefix, '/usr/local/lib', '/usr/lib']) {
    if (typeof prefix === 'string' && prefix.length > 0) roots.push(join(prefix, 'node_modules', '@deepseek-ai', 'dsh'))
  }
  return roots
}

function parseArgs(argv) {
  const [command, ...rest] = argv
  const options = {}
  for (let index = 0; index < rest.length; index += 1) {
    const arg = rest[index]
    if (arg === '--home') options.home = rest[++index]
    else if (arg === '--ref') options.ref = rest[++index]
    else if (arg === '--quiet') options.quiet = true
    else fail(`unknown option ${arg}`)
  }
  return { command, options }
}

function fingerprint(value) {
  return createHash('sha256').update(value).digest('hex').slice(0, 12)
}

async function readDocument(path, yaml) {
  let text
  try {
    text = await readFile(path, 'utf8')
  } catch (error) {
    if (error?.code === 'ENOENT') return { text: '', document: undefined }
    throw error
  }
  const document = yaml.parseDocument(text)
  if (document.errors.length > 0) {
    fail(`${path} is not valid YAML (${document.errors[0].code}); fix or remove it before rerunning`, 2)
  }
  const root = document.toJS()
  if (root !== null && root !== undefined && (typeof root !== 'object' || Array.isArray(root))) {
    fail(`${path} is not a mapping; fix or remove it before rerunning`, 2)
  }
  return { text, document }
}

async function writeDocument(path, text) {
  const directory = dirname(path)
  await mkdir(directory, { recursive: true, mode: 0o700 })
  const temporary = `${path}.tmp-${process.pid}`
  await writeFile(temporary, text, { mode: 0o600 })
  await chmod(temporary, 0o600)
  await rename(temporary, path)
}

async function withOwnerOnly(path) {
  try {
    const info = await stat(path)
    if ((info.mode & 0o077) !== 0) {
      // The runtime refuses to boot on a document other users can read; fixing
      // the mode is the repair, not a warning.
      await chmod(path, 0o600)
      return 'mode'
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error
  }
  return undefined
}

async function backup(path) {
  try {
    const text = await readFile(path)
    await writeFile(`${path}.bak`, text, { mode: 0o600 })
    await chmod(`${path}.bak`, 0o600)
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error
  }
}

async function main() {
  const { command, options } = parseArgs(process.argv.slice(2))
  if (!['status', 'sync', 'clear'].includes(command)) {
    fail('usage: credentials.mjs <status|sync|clear> --home <DSH_HOME> --ref <NAME>')
  }
  const home = options.home
  const ref = options.ref
  if (typeof home !== 'string' || home.length === 0) fail('--home is required')
  if (typeof ref !== 'string' || !REF_PATTERN.test(ref)) fail('--ref must be an environment-variable name')
  const path = join(home, FILENAME)
  const yaml = loadYaml()
  const repairedMode = await withOwnerOnly(path)

  const { document } = await readDocument(path, yaml)
  const stored = document?.getIn?.(['refs', ref])
  const value = typeof stored === 'string' && stored.length > 0 ? stored : undefined
  const wanted = process.env.DSH_VALUE

  if (command === 'status') {
    if (value === undefined) {
      process.stdout.write('absent\n')
      return
    }
    if (wanted === undefined || wanted.length === 0) {
      process.stdout.write(`present ${fingerprint(value)}\n`)
      return
    }
    process.stdout.write(value === wanted ? 'match\n' : `different ${fingerprint(value)} ${fingerprint(wanted)}\n`)
    return
  }

  if (command === 'clear') {
    if (value === undefined) {
      process.stdout.write('absent\n')
      return
    }
    await backup(path)
    document.deleteIn(['refs', ref])
    await writeDocument(path, String(document))
    process.stdout.write('removed\n')
    return
  }

  // sync
  if (typeof wanted !== 'string' || wanted.length === 0) fail('sync needs DSH_VALUE (the key to store)')
  if (value === wanted) {
    process.stdout.write('unchanged\n')
    return
  }
  await backup(path)
  const next = document ?? new yaml.Document({ version: 1, refs: {} })
  if (next.get('version') === undefined) next.set('version', 1)
  if (next.get('refs') === undefined) next.set('refs', {})
  next.setIn(['refs', ref], wanted)
  await writeDocument(path, String(next))
  process.stdout.write(value === undefined ? 'created\n' : 'updated\n')
}

main().catch((error) => {
  // Never echo the document or the value: the message is a path or a syscall.
  fail(error instanceof Error ? error.message : String(error))
})
