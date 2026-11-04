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
 * or drop the stored entry so the environment applies again.
 *
 * ## Why this does not use a YAML library
 *
 * The helper runs on the deployment host, before `dsh` is necessarily usable
 * (bootstrap, repair after a broken install) and in CI, where the setup repo has
 * no dependencies at all. A `yaml` import would work only where a global DSH is
 * installed — which is exactly the situation a repair cannot assume. The
 * document the runtime writes is a fixed shape (`version`, `refs`, `records`),
 * so the helper edits that shape directly and refuses anything it does not
 * recognize, rather than guessing:
 *
 *   version: 1
 *   refs:
 *     OPENCODE_GO_API_KEY: sk-…
 *   records:
 *     provider/…
 *
 * Values are rewritten as double-quoted YAML scalars (`JSON.stringify`, which is
 * valid YAML double-quoted syntax for the ASCII keys these references hold) and
 * the previous document is kept as `.credentials.yaml.bak` (0600).
 *
 * Secret material travels through the environment, never argv (argv is
 * world-readable in `ps`).
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

import { createHash } from 'node:crypto'
import { chmod, mkdir, readFile, rename, stat, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'

const FILENAME = '.credentials.yaml'
const REF_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/
const SECTION_PATTERN = /^([A-Za-z_][A-Za-z0-9_-]*):(.*)$/
const ENTRY_PATTERN = /^(\s+)([A-Za-z_][A-Za-z0-9_]*):(.*)$/

function fail(message, code = 1) {
  process.stderr.write(`credentials: ${message}\n`)
  process.exit(code)
}

function parseArgs(argv) {
  const [command, ...rest] = argv
  const options = {}
  for (let index = 0; index < rest.length; index += 1) {
    const arg = rest[index]
    if (arg === '--home') options.home = rest[++index]
    else if (arg === '--ref') options.ref = rest[++index]
    else fail(`unknown option ${arg}`)
  }
  return { command, options }
}

function fingerprint(value) {
  return createHash('sha256').update(value).digest('hex').slice(0, 12)
}

/** Undo the quoting a YAML writer may have used for one scalar. */
function parseScalar(raw) {
  const text = raw.trim()
  if (text.length === 0) return ''
  if (text.startsWith('"')) {
    if (!text.endsWith('"') || text.length < 2) return undefined
    try {
      const parsed = JSON.parse(text)
      return typeof parsed === 'string' ? parsed : undefined
    } catch {
      return undefined
    }
  }
  if (text.startsWith("'")) {
    if (!text.endsWith("'") || text.length < 2) return undefined
    return text.slice(1, -1).replaceAll("''", "'")
  }
  // A plain scalar ends at an unescaped " #" comment, as YAML reads it.
  const comment = text.search(/\s#/)
  return (comment === -1 ? text : text.slice(0, comment)).trimEnd()
}

/** Write a string the YAML reader will read back verbatim. */
function quoteScalar(value) {
  return JSON.stringify(value)
}

/**
 * Parse the fixed document shape. An absent file is an empty document; anything
 * present that is not the version-1 layout is rejected rather than edited.
 */
function parseDocument(text, path) {
  if (text.length === 0) {
    return { lines: [], versionLine: -1, refsLine: -1, refsInline: false, entries: new Map() }
  }
  const lines = text.split('\n')
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop()
  let versionLine = -1
  let refsLine = -1
  let refsInline = false
  const entries = new Map()
  let inRefs = false
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]
    if (/^\s*#/.test(line) || line.trim().length === 0) continue
    const section = SECTION_PATTERN.exec(line)
    if (section !== null) {
      inRefs = false
      const [, name, rest] = section
      if (name === 'version') {
        versionLine = index
        const declared = (parseScalar(rest) ?? '').trim()
        if (declared !== '1') {
          fail(`${path} declares an unexpected document version (${declared || 'none'}); this build reads version 1`, 2)
        }
      } else if (name === 'refs') {
        refsLine = index
        const inline = rest.trim()
        if (inline.length > 0) {
          // `refs: {}` is how the runtime renders an empty map.
          if (inline === '{}') {
            refsInline = true
            inRefs = true
            continue
          }
          fail(`${path} has a refs section this build cannot edit safely (${inline}); fix it by hand`, 2)
        }
        inRefs = true
      }
      continue
    }
    if (!inRefs) continue
    const entry = ENTRY_PATTERN.exec(line)
    if (entry === null) {
      fail(`${path} has an unexpected line inside refs; fix it by hand`, 2)
    }
    const [, indent, name, rest] = entry
    if (entries.has(name)) {
      fail(`${path} assigns ${name} twice inside refs; fix it by hand`, 2)
    }
    const value = parseScalar(rest)
    if (value === undefined) {
      fail(`${path} has an unreadable value for ${name}; fix it by hand`, 2)
    }
    entries.set(name, { line: index, indent, value })
  }
  if (versionLine === -1) {
    fail(`${path} has no \`version: 1\`; it is not a credentials document this build reads`, 2)
  }
  return { lines, versionLine, refsLine, refsInline, entries }
}

async function readDocument(path) {
  let text
  try {
    text = await readFile(path, 'utf8')
  } catch (error) {
    if (error?.code === 'ENOENT') return parseDocument('', path)
    throw error
  }
  return parseDocument(text, path)
}

async function ownerOnly(path) {
  try {
    const info = await stat(path)
    if ((info.mode & 0o077) !== 0) {
      // The runtime refuses to boot on a document other users can read; fixing
      // the mode is the repair, not a warning.
      await chmod(path, 0o600)
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error
  }
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

async function writeDocument(path, text) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = `${path}.tmp-${process.pid}`
  await writeFile(temporary, text, { mode: 0o600 })
  await chmod(temporary, 0o600)
  await rename(temporary, path)
}

/** Render the document with one ref set (a value) or removed (undefined). */
function render(doc, ref, value) {
  // eslint-disable-next-line prefer-const -- reassigned only when seeding version
  let mutableDoc = doc
  const lines = [...mutableDoc.lines]
  const existing = mutableDoc.entries.get(ref)
  const renderLine = (indent) => `${indent}${ref}: ${quoteScalar(value)}`

  if (value === undefined) {
    if (existing === undefined) return doc.lines.length === 0 ? '' : `${lines.join('\n')}\n`
    lines.splice(existing.line, 1)
    // Leave an explicitly empty map, the same shape the runtime writes, so the
    // document never ends with a `refs:` key that parses as null.
    const remaining = [...doc.entries.keys()].filter((name) => name !== ref)
    if (remaining.length === 0 && doc.refsLine !== -1) {
      lines[doc.refsLine] = 'refs: {}'
      while (lines[doc.refsLine + 1] !== undefined && lines[doc.refsLine + 1].trim() === '') lines.splice(doc.refsLine + 1, 1)
    }
    return `${lines.join('\n')}\n`
  }

  if (existing !== undefined) {
    lines[existing.line] = renderLine(existing.indent)
    return `${lines.join('\n')}\n`
  }

  if (doc.refsLine === -1) {
    // No refs section yet. An empty file must get the version header too: the
    // runtime rejects an unversioned document (it reads as the pre-release
    // flat layout), and this helper creates the file on a fresh deployment.
    if (mutableDoc.versionLine === -1) {
      lines.push('version: 1')
      mutableDoc = { ...mutableDoc, versionLine: lines.length - 1 }
    }
    const at = mutableDoc.versionLine + 1
    lines.splice(at, 0, 'refs:', renderLine('  '))
    return `${lines.join('\n')}\n`
  }

  if (doc.refsInline) {
    lines[doc.refsLine] = 'refs:'
    lines.splice(doc.refsLine + 1, 0, renderLine('  '))
    return `${lines.join('\n')}\n`
  }

  lines.splice(doc.refsLine + 1, 0, renderLine('  '))
  return `${lines.join('\n')}\n`
}

async function main() {
  const { command, options } = parseArgs(process.argv.slice(2))
  if (!['status', 'sync', 'clear'].includes(command)) {
    fail('usage: credentials.mjs <status|sync|clear> --home <DSH_HOME> --ref <NAME>')
  }
  if (typeof options.home !== 'string' || options.home.length === 0) fail('--home is required')
  if (typeof options.ref !== 'string' || !REF_PATTERN.test(options.ref)) fail('--ref must be an environment-variable name')
  const path = join(options.home, FILENAME)
  await ownerOnly(path)
  const doc = await readDocument(path)
  const stored = doc.entries.get(options.ref)?.value
  const value = stored !== undefined && stored.length > 0 ? stored : undefined
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
    await writeDocument(path, render(doc, options.ref, undefined))
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
  await writeDocument(path, render(doc, options.ref, wanted))
  process.stdout.write(value === undefined ? 'created\n' : 'updated\n')
}

main().catch((error) => {
  // Never echo the document or the value: the message is a path or a syscall.
  fail(error instanceof Error ? error.message : String(error))
})
