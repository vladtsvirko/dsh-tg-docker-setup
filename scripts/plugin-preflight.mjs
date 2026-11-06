#!/usr/bin/env node
/**
 * Release preflight for the plugin pins.
 *
 * The setup installs each plugin from an exact npm spec and keeps the same
 * release on GitHub as the registry-unreachable fallback. Before tagging the
 * setup, both halves must agree and (with --remote) actually exist.
 *
 *   node scripts/plugin-preflight.mjs            # local checkout, no network
 *   node scripts/plugin-preflight.mjs --remote   # requires published packages
 *
 * `--remote` is deliberately not in CI: before a release it is expected to
 * fail. Run it as the last step of the setup release checklist.
 */
import { execFile } from 'node:child_process'
import { readFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const exec = promisify(execFile)
const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const remote = process.argv.includes('--remote')

const fail = (message) => {
  console.error(`plugin-preflight: ${message}`)
  process.exitCode = 1
}

const compare = (left, right) => {
  const one = String(left).split(/[.-]/).slice(0, 3).map(Number)
  const two = String(right).split(/[.-]/).slice(0, 3).map(Number)
  for (let index = 0; index < 3; index += 1) {
    if (one[index] !== two[index]) return one[index] < two[index] ? -1 : 1
  }
  return 0
}

const npmSpec = (spec) => {
  const match = /^((?:@[^/]+\/)?[^@]+)@([0-9][^@]*)$/.exec(spec ?? '')
  return match === null ? undefined : { name: match[1], version: match[2] }
}
const githubSpec = (spec) => {
  const match = /^github:([^/#]+)\/([^/#]+)#(v[^/]+)$/.exec(spec ?? '')
  return match === null ? undefined : { owner: match[1], repo: match[2], tag: match[3] }
}

const catalog = JSON.parse(await readFile(join(root, 'plugins.json'), 'utf8'))
const entries = Object.entries(catalog.plugins ?? {})
if (entries.length === 0) fail('plugins.json has no plugins')

for (const [name, entry] of entries) {
  const spec = entry.spec ?? entry.ref
  const npm = npmSpec(spec)
  const fallback = githubSpec(entry.fallback)
  if (npm === undefined) {
    fail(`${name}: spec ${JSON.stringify(spec)} is not an exact npm package@version`)
    continue
  }
  if (fallback === undefined) {
    fail(`${name}: fallback ${JSON.stringify(entry.fallback)} is not github:owner/repo#v<version>`)
  } else if (fallback.tag.replace(/^v/, '') !== npm.version) {
    fail(`${name}: npm ${npm.version} and fallback ${fallback.tag} disagree`)
  }
  if (entry.minimum !== undefined && compare(entry.minimum, npm.version) > 0) {
    fail(`${name}: minimum ${entry.minimum} is above the pinned ${npm.version}`)
  }

  const local = join(root, '..', npm.name.split('/').pop(), 'package.json')
  try {
    const pkg = JSON.parse(await readFile(local, 'utf8'))
    if (pkg.version !== npm.version) {
      fail(`${name}: ${npm.name}/package.json is ${pkg.version}, plugins.json pins ${npm.version}`)
    } else {
      console.log(`${name}: local ${npm.name} ${pkg.version} matches ${spec}`)
    }
  } catch {
    console.log(`${name}: sibling checkout not found; local check skipped`)
  }

  if (!remote) continue

  const registry = (process.env.DSH_NPM_REGISTRY ?? 'https://registry.npmjs.org').replace(/\/+$/, '')
  try {
    const response = await fetch(`${registry}/${encodeURIComponent(npm.name)}/${npm.version}`, {
      headers: { 'user-agent': 'dsh-tg-docker-setup' },
    })
    if (!response.ok) throw new Error(`registry answered ${String(response.status)}`)
    const body = await response.json()
    if (body.version !== npm.version) throw new Error(`registry returned ${String(body.version)}`)
    console.log(`${name}: npm ${npm.name}@${npm.version} exists`)
  } catch (error) {
    fail(`${name}: npm ${npm.name}@${npm.version} is not published (${error instanceof Error ? error.message : String(error)})`)
  }

  if (fallback !== undefined) {
    try {
      await exec('git', [
        'ls-remote', '--exit-code', '--tags',
        `https://github.com/${fallback.owner}/${fallback.repo}.git`, `refs/tags/${fallback.tag}`,
      ])
      console.log(`${name}: fallback tag ${fallback.tag} exists`)
    } catch {
      fail(`${name}: ${fallback.owner}/${fallback.repo} has no tag ${fallback.tag}`)
    }
  }
}

console.log('')
console.log(`plugin preflight ${process.exitCode === 1 ? 'failed' : 'ok'}${remote ? ' (remote)' : ' (local)'}`)
