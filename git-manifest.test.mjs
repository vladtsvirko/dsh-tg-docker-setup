import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtemp, readFile, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const script = join(here, 'scripts', 'git-manifest.mjs')

const read = async (file) => JSON.parse(await readFile(file, 'utf8'))

function build(file, accounts, extra = []) {
  return execFileSync(process.execPath, [script, '--file', file, ...extra], {
    input: JSON.stringify(accounts),
    encoding: 'utf8',
  })
}

test('one account is written as the default profile', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'git-manifest-'))
  const file = join(dir, 'profiles.json')
  build(file, [{ provider: 'github', auth: 'https', token: 'ghp_one' }], ['--name', 'Vlad', '--email', 'vlad@example.com'])
  const manifest = await read(file)
  assert.equal(manifest.default.provider, 'github')
  assert.equal(manifest.default.token, 'ghp_one')
  assert.deepEqual(manifest.default.identity, { name: 'Vlad', email: 'vlad@example.com' })
  assert.deepEqual(manifest.projects, {})
  assert.equal(manifest.hosts, undefined)
  assert.equal((await stat(file)).mode & 0o077, 0)
})

test('several accounts are host-scoped, with no global default', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'git-manifest-'))
  const file = join(dir, 'profiles.json')
  build(file, [
    { provider: 'github', auth: 'https', token: 'ghp_one' },
    { provider: 'gitlab', auth: 'https', token: 'glpat_two' },
    { provider: 'gitea', host: 'git.example.com', auth: 'ssh', key: 'team_ed25519', known_hosts: 'known_hosts' },
  ])
  const manifest = await read(file)
  assert.equal(manifest.default, undefined)
  assert.deepEqual(Object.keys(manifest.hosts).sort(), ['git.example.com', 'github.com', 'gitlab.com'])
  assert.equal(manifest.hosts['github.com'].token, 'ghp_one')
  assert.equal(manifest.hosts['git.example.com'].auth, 'ssh')
})

test('--merge adds a host and keeps the default and the projects', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'git-manifest-'))
  const file = join(dir, 'profiles.json')
  await writeFile(file, JSON.stringify({
    default: { provider: 'github', auth: 'https', token: 'ghp_old' },
    projects: { 'web-app': { provider: 'gitlab', auth: 'https', token: 'glpat_project' } },
  }))
  build(file, [{ provider: 'gitlab', auth: 'https', token: 'glpat_new' }], ['--merge'])
  const manifest = await read(file)
  assert.equal(manifest.default.token, 'ghp_old')
  assert.equal(manifest.projects['web-app'].token, 'glpat_project')
  assert.equal(manifest.hosts['gitlab.com'].token, 'glpat_new')
})

test('--merge replaces an entry for the same host', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'git-manifest-'))
  const file = join(dir, 'profiles.json')
  await writeFile(file, JSON.stringify({ hosts: { 'github.com': { provider: 'github', auth: 'https', token: 'old' } }, projects: {} }))
  build(file, [{ provider: 'github', auth: 'https', token: 'new' }], ['--merge'])
  const manifest = await read(file)
  assert.equal(manifest.hosts['github.com'].token, 'new')
})

function failure(accounts) {
  const dir = execFileSync('mktemp', ['-d'], { encoding: 'utf8' }).trim()
  try {
    build(join(dir, 'profiles.json'), accounts)
  } catch (error) {
    return String(error.stderr ?? error.message)
  } finally {
    execFileSync('rm', ['-rf', dir])
  }
  return ''
}

test('rejects incomplete or impossible accounts', () => {
  assert.match(failure([{ provider: 'github', auth: 'https' }]), /"token"/)
  assert.match(failure([{ provider: 'gitea', auth: 'https', token: 'x' }]), /needs a host/)
  assert.match(
    failure([{ provider: 'gitea', host: 'git.example.com', auth: 'ssh', key: 'k' }]),
    /"known_hosts"/,
  )
  assert.match(failure([]), /no accounts/)
})
