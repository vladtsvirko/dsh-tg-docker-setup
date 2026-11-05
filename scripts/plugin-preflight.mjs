#!/usr/bin/env node
/**
 * Release preflight for the plugin pins.
 *
 * The setup no longer needs a connector tag, but a fresh install still resolves
 * `plugins.json`. This checks the two places that can drift before a tag:
 *
 *   - local: the sibling repositories' package versions match their pinned tag;
 *   - remote: the pinned tags actually exist on GitHub.
 *
 *   node scripts/plugin-preflight.mjs            # local checkout, no network
 *   node scripts/plugin-preflight.mjs --remote   # requires the tags to be pushed
 *
 * It is deliberately not in CI: before the tags exist, `--remote` is expected
 * to fail. Run it as the last step of the release checklist.
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
  const one = left.replace(/^v/, '').split(/[.-]/).slice(0, 3).map(Number)
  const two = right.replace(/^v/, '').split(/[.-]/).slice(0, 3).map(Number)
  for (let index = 0; index < 3; index += 1) {
    if (one[index] !== two[index]) return one[index] < two[index] ? -1 : 1
  }
  return 0
}

const catalog = JSON.parse(await readFile(join(root, 'plugins.json'), 'utf8'))
const entries = Object.entries(catalog.plugins ?? {})
if (entries.length === 0) fail('plugins.json has no plugins')

for (const [name, entry] of entries) {
  const match = /^github:([^/#]+)\/([^/#]+)#(v[^/]+)$/.exec(entry.ref ?? '')
  if (match === null) {
    fail(`${name}: ref ${JSON.stringify(entry.ref)} is not github:owner/repo#v<version>`)
    continue
  }
  const [, owner, repo, tag] = match
  const version = tag.replace(/^v/, '')
  if (compare(entry.minimum ?? '0.0.0', version) > 0) {
    fail(`${name}: minimum ${entry.minimum} is above the pinned tag ${tag}`)
  }

  const local = join(root, '..', repo, 'package.json')
  try {
    const pkg = JSON.parse(await readFile(local, 'utf8'))
    if (pkg.version !== version) {
      fail(`${name}: ${repo}/package.json is ${pkg.version}, plugins.json pins ${tag}`)
    } else {
      console.log(`${name}: local ${repo} ${pkg.version} matches ${tag}`)
    }
  } catch {
    console.log(`${name}: sibling checkout not found; local check skipped`)
  }

  if (remote) {
    try {
      await exec('git', [
        'ls-remote', '--exit-code', '--tags',
        `https://github.com/${owner}/${repo}.git`, `refs/tags/${tag}`,
      ])
      console.log(`${name}: remote tag ${tag} exists`)
    } catch {
      fail(`${name}: ${owner}/${repo} has no tag ${tag} — push the plugin tag before the setup tag`)
    }
  }
}

console.log('')
console.log(`plugin preflight ${process.exitCode === 1 ? 'failed' : 'ok'}${remote ? ' (remote)' : ' (local)'}`)
