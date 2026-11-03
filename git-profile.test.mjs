/**
 * Tests for scripts/git-profile.sh — the manifest the installer writes for the
 * agent's repository access.
 *
 * A token with a quote in it used to be the difference between "git works" and
 * "the plugin fails at boot", so the escaping is what these assert.
 *
 *   node --test git-profile.test.mjs
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { chmod, mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const here = dirname(fileURLToPath(import.meta.url))
const exec = promisify(execFile)

/** Run one shell snippet with the helper sourced. */
async function shell(snippet) {
  const { stdout } = await exec('bash', ['-c', `. "${join(here, 'scripts', 'git-profile.sh')}"\n${snippet}`])
  return stdout
}

test('a github profile is valid JSON with the token and identity', async () => {
  const json = await shell('git_profile_json github "" "ghp_abc" "Vlad" "vlad@example.test"')
  const parsed = JSON.parse(json)
  assert.equal(parsed.default.provider, 'github')
  assert.equal(parsed.default.auth, 'https')
  assert.equal(parsed.default.token, 'ghp_abc')
  assert.deepEqual(parsed.default.identity, { name: 'Vlad', email: 'vlad@example.test' })
  assert.deepEqual(parsed.projects, {})
  assert.equal(parsed.default.host, undefined)
})

test('a self-hosted profile carries its host', async () => {
  const parsed = JSON.parse(await shell('git_profile_json self-hosted "git.example.test" "t" "" ""'))
  assert.equal(parsed.default.provider, 'self-hosted')
  assert.equal(parsed.default.host, 'git.example.test')
  assert.equal(parsed.default.identity, undefined)
})

test('a token with quotes or backslashes survives the round trip', async () => {
  // Nothing stops a self-hosted provider from issuing these characters.
  const token = 'a"b\\c\\\\d'
  const parsed = JSON.parse(await shell(`git_profile_json github "" '${token}' "" ""`))
  assert.equal(parsed.default.token, token)
})

test('the manifest is written 0600, with a backup on rewrite', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'git-profile-'))
  try {
    const target = join(dir, 'git')
    const first = await shell(`git_profile_write "${target}" "" github "" "tok" "A" "a@b.test"`)
    assert.equal(first.trim(), join(target, 'profiles.json'))
    assert.equal((await stat(join(target, 'profiles.json'))).mode & 0o777, 0o600)
    assert.equal(JSON.parse(await readFile(join(target, 'profiles.json'), 'utf8')).default.token, 'tok')

    await shell(`git_profile_write "${target}" "" gitlab "" "tok2" "A" "a@b.test"`)
    const entries = await readdir(target)
    assert.ok(entries.some((name) => name.startsWith('profiles.json.bak-')), entries.join(','))
    assert.equal(JSON.parse(await readFile(join(target, 'profiles.json'), 'utf8')).default.provider, 'gitlab')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('a broken token is reported instead of written silently', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'git-profile-bad-'))
  try {
    const target = join(dir, 'git')
    // A raw control character cannot be escaped by the helper, so the writer
    // must refuse rather than leave a manifest git cannot read.
    let failed = false
    try {
      await shell(`git_profile_write "${target}" "" github "" $\x27line1\\nline2\x27 "A" "a@b.test"`)
    } catch {
      failed = true
    }
    assert.equal(failed, true, 'the writer must fail on unrepresentable input')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})
