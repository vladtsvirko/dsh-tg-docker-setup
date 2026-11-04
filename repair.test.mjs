/**
 * Tests for the shared deployment doctor (scripts/repair.sh) and its credential
 * helper (scripts/credentials.mjs).
 *
 * These are the checks a repair run relies on: the two failures that look like
 * "model calls stopped working after I re-ran install.sh" are a key assigned
 * twice in .env (the runtime reads the last one, which is not the line the file
 * invites you to edit) and a stored credential that outranks .env in the
 * runtime's own resolution order. Both must be detected without printing either
 * secret, and both must be repairable in place.
 *
 *   node --test repair.test.mjs
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { mkdtemp, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const here = dirname(fileURLToPath(import.meta.url))
const exec = promisify(execFile)
const repair = join(here, 'scripts', 'repair.sh')
const credentials = join(here, 'scripts', 'credentials.mjs')

/**
 * A deterministic "docker is installed but unusable" binary.
 *
 * The doctor treats an unreachable daemon as a warning, not a failure: a host
 * can legitimately run without Docker. A CI runner does have a working daemon,
 * where `docker compose ps` against a throwaway directory answers "no
 * container" — a failure. The tests must not read the machine they run on, so
 * they shadow `docker` with one that fails every call.
 */
const shimDir = await mkdtemp(join(tmpdir(), 'repair-docker-shim-'))
await writeFile(join(shimDir, 'docker'), '#!/bin/sh\nexit 1\n', { mode: 0o755 })
const shimEnv = { PATH: `${shimDir}:${process.env.PATH ?? ''}` }

async function run(args, { env = {}, cwd = here } = {}) {
  try {
    const { stdout, stderr } = await exec('bash', [repair, ...args], {
      cwd,
      env: { ...process.env, ...shimEnv, ...env },
    })
    return { code: 0, out: stdout + stderr }
  } catch (error) {
    return { code: error.code ?? 1, out: String(error.stdout ?? '') + String(error.stderr ?? '') }
  }
}

/** A deployment directory with a .env and data/home, in the given mode. */
async function fixture(mode = 'docker', env = {}) {
  const dir = await mkdtemp(join(tmpdir(), `repair-${mode}-`))
  const port = String(45000 + Math.floor(Math.random() * 1000))
  const values = {
    MODE: mode,
    DSH_PORT: port,
    DSH_BIND_IP: '127.0.0.1',
    DSH_PROVIDER: 'opencode-go',
    DSH_MODEL: 'deepseek-v4.1-flash',
    OPENCODE_GO_API_KEY: 'sk-test-key-that-is-long-enough',
    DSH_TELEGRAM_BOT_TOKEN: '',
    DSH_TELEGRAM_ENABLED: 'auto',
    DSH_UPDATER_TOKEN: 'updater-token-for-the-test',
    DSH_SETUP_VERSION: (await readFile(join(here, 'VERSION'), 'utf8')).trim(),
    DSH_UID: '1000',
    DSH_GID: '1000',
    ...env,
  }
  const body = Object.entries(values)
    .filter(([, value]) => value !== undefined)
    .map(([key, value]) => `${key}=${value}`)
    .join('\n')
  await writeFile(join(dir, '.env'), `${body}\n`, { mode: 0o600 })
  await writeFile(join(dir, 'VERSION'), `${values.DSH_SETUP_VERSION}\n`)
  await mkdir(join(dir, 'data', 'home', 'profiles', 'web'), { recursive: true })
  return dir
}

test('a clean deployment is reported clean and exits zero', async () => {
  const dir = await fixture()
  try {
    const { code, out } = await run(['--dir', dir, '--mode', 'docker'])
    assert.equal(code, 0, out)
    assert.match(out, /ok\s+env-file\s+one value per key/)
    assert.match(out, /ok\s+provider-key\s+OPENCODE_GO_API_KEY is set/)
    assert.match(out, /ok\s+credential-store\s+no stored credential/)
    // Docker on a host without docker is a warning, not a failure.
    assert.match(out, /clean \(\d+ warning\(s\)\)/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('a key assigned twice is a failure, and --fix keeps the last assignment', async () => {
  const dir = await fixture('docker', {})
  try {
    const env = `${await readFile(join(dir, '.env'), 'utf8')}OPENCODE_GO_API_KEY=sk-old-key-that-is-long-enough\nOPENCODE_GO_API_KEY=sk-new-key-that-is-long-enough\n`
    await writeFile(join(dir, '.env'), env)

    const broken = await run(['--dir', dir, '--mode', 'docker'])
    assert.equal(broken.code, 1)
    assert.match(broken.out, /fail\s+env-file\s+assigned more than once: OPENCODE_GO_API_KEY/)

    const fixed = await run(['--dir', dir, '--mode', 'docker', '--fix'])
    const text = await readFile(join(dir, '.env'), 'utf8')
    const lines = text.split('\n').filter((line) => line.startsWith('OPENCODE_GO_API_KEY='))
    assert.equal(lines.length, 1, 'exactly one assignment survives')
    assert.equal(lines[0], 'OPENCODE_GO_API_KEY=sk-new-key-that-is-long-enough')
    assert.match(fixed.out, /fix\s+env-file/)
    assert.equal(fixed.code, 0, fixed.out)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('a CRLF line is normalized rather than read as part of the value', async () => {
  const dir = await fixture('docker', {})
  try {
    const env = `${await readFile(join(dir, '.env'), 'utf8')}DSH_PUBLIC_URL=http://example.test:4310/\r\n`
    await writeFile(join(dir, '.env'), env)
    const broken = await run(['--dir', dir, '--mode', 'docker'])
    assert.equal(broken.code, 1)
    assert.match(broken.out, /end with CR/)
    await run(['--dir', dir, '--mode', 'docker', '--fix'])
    const text = await readFile(join(dir, '.env'), 'utf8')
    assert.doesNotMatch(text, /\r/)
    assert.match(text, /DSH_PUBLIC_URL=http:\/\/example\.test:4310\//)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('a whitespace-bearing key is refused with the reason, not just "fails"', async () => {
  const dir = await fixture('docker', { OPENCODE_GO_API_KEY: 'sk-key with-a-space' })
  try {
    const { code, out } = await run(['--dir', dir, '--mode', 'docker'])
    assert.equal(code, 1)
    assert.match(out, /fail\s+provider-key\s+OPENCODE_GO_API_KEY contains whitespace/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('an empty provider key is a warning: the runtime boots and every call fails', async () => {
  const dir = await fixture('docker', { OPENCODE_GO_API_KEY: '' })
  try {
    const { code, out } = await run(['--dir', dir, '--mode', 'docker'])
    assert.equal(code, 0, out)
    assert.match(out, /warn\s+provider-key\s+OPENCODE_GO_API_KEY is empty/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('a stored credential that shadows .env is a failure and --fix makes the deployment key win', async () => {
  const dir = await fixture()
  const store = join(dir, 'data', 'home', '.credentials.yaml')
  try {
    await writeFile(store, 'version: 1\nrefs:\n  OPENCODE_GO_API_KEY: sk-the-old-one-from-the-ui\n', { mode: 0o600 })

    const broken = await run(['--dir', dir, '--mode', 'docker'])
    assert.equal(broken.code, 1)
    assert.match(broken.out, /fail\s+credential-store\s+the web UI stores a different OPENCODE_GO_API_KEY/)
    // The message must not leak either value.
    assert.doesNotMatch(broken.out, /sk-the-old-one-from-the-ui/)
    assert.doesNotMatch(broken.out, /sk-test-key-that-is-long-enough/)

    const fixed = await run(['--dir', dir, '--mode', 'docker', '--fix'])
    const text = await readFile(store, 'utf8')
    assert.match(text, /OPENCODE_GO_API_KEY: sk-test-key-that-is-long-enough/)
    assert.doesNotMatch(text, /sk-the-old-one-from-the-ui/)
    assert.match(fixed.out, /fix\s+credential-store/)
    // A backup keeps the previous document without losing it.
    const backup = await readFile(`${store}.bak`, 'utf8')
    assert.match(backup, /sk-the-old-one-from-the-ui/)
    assert.equal((await stat(store)).mode & 0o777, 0o600)
    assert.equal(fixed.code, 0, fixed.out)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('a duplicated managed block in cordis.patch.yml is removed, keeping the first copy', async () => {
  const dir = await fixture()
  const patch = join(dir, 'data', 'home', 'profiles', 'web', 'cordis.patch.yml')
  const block = [
    '# >>> dsh-provider (managed by entrypoint.sh — edits here are overwritten)',
    '- id: llm-pi-ai',
    '  config:',
    '    providers:',
    '      opencode-go:',
    '        apiKeyEnv: OPENCODE_GO_API_KEY',
    '# <<< dsh-provider',
  ].join('\n')
  try {
    await writeFile(patch, `${block}\n${block}\n`)
    const broken = await run(['--dir', dir, '--mode', 'docker'])
    assert.equal(broken.code, 1)
    assert.match(broken.out, /fail\s+patch\s+.*duplicated/)

    const fixed = await run(['--dir', dir, '--mode', 'docker', '--fix'])
    const text = await readFile(patch, 'utf8')
    assert.equal(text.match(/# >>> dsh-provider/g)?.length, 1)
    assert.equal(text.match(/# <<< dsh-provider/g)?.length, 1)
    assert.match(fixed.out, /fix\s+patch/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('a live marker from another mode is a failure; the same mode is fine', async () => {
  const dir = await fixture('docker')
  const marker = join(dir, 'data', '.runtime.json')
  try {
    // This test process stands in for a running runtime: it is alive.
    await writeFile(marker, `${JSON.stringify({ mode: 'native', pid: process.pid, startedAt: '2026-01-01T00:00:00Z' })}\n`)
    const other = await run(['--dir', dir, '--mode', 'docker'])
    assert.equal(other.code, 1)
    assert.match(other.out, /fail\s+instance\s+a native runtime is using/)

    await writeFile(marker, `${JSON.stringify({ mode: 'docker', pid: process.pid, startedAt: '2026-01-01T00:00:00Z' })}\n`)
    const same = await run(['--dir', dir, '--mode', 'docker'])
    assert.equal(same.code, 0, same.out)
    assert.match(same.out, /ok\s+instance\s+the docker runtime owns/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('a stale marker from a dead pid is not a failure', async () => {
  const dir = await fixture('docker')
  try {
    // 999999 is above the default pid_max on every Linux distribution.
    await writeFile(join(dir, 'data', '.runtime.json'), '{"mode":"native","pid":999999,"startedAt":"2026-01-01T00:00:00Z"}\n')
    const { code, out } = await run(['--dir', dir, '--mode', 'docker'])
    assert.equal(code, 0, out)
    assert.match(out, /ok\s+instance\s+no live runtime/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('install.sh --doctor runs the doctor instead of installing', async () => {
  const dir = await fixture()
  try {
    const { stdout } = await exec('bash', [join(here, 'install.sh'), '--doctor', '--dir', dir], {
      timeout: 20000,
      env: { ...process.env, ...shimEnv },
    })
    assert.match(stdout, /checking docker deployment/)
    assert.match(stdout, /provider-key/)
    assert.doesNotMatch(stdout, /==> plan/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('credentials.mjs never prints a secret and preserves unrelated entries', async () => {
  const home = await mkdtemp(join(tmpdir(), 'credentials-'))
  try {
    const path = join(home, '.credentials.yaml')
    await writeFile(path, '# a comment the user wrote\nversion: 1\nrefs:\n  OTHER_KEY: keep-me\n', { mode: 0o600 })

    const set = await exec('node', [credentials, 'sync', '--home', home, '--ref', 'OPENCODE_GO_API_KEY'], {
      env: { ...process.env, DSH_VALUE: 'sk-secret-value' },
    })
    assert.equal(set.stdout.trim(), 'created')
    assert.doesNotMatch(set.stdout + set.stderr, /sk-secret-value/)

    const status = await exec('node', [credentials, 'status', '--home', home, '--ref', 'OPENCODE_GO_API_KEY'], {
      env: { ...process.env, DSH_VALUE: 'sk-secret-value' },
    })
    assert.equal(status.stdout.trim(), 'match')

    const text = await readFile(path, 'utf8')
    assert.match(text, /OTHER_KEY: keep-me/)
    assert.match(text, /OPENCODE_GO_API_KEY: sk-secret-value/)
    assert.equal((await stat(path)).mode & 0o777, 0o600)

    await exec('node', [credentials, 'clear', '--home', home, '--ref', 'OPENCODE_GO_API_KEY'])
    const cleared = await readFile(path, 'utf8')
    assert.doesNotMatch(cleared, /OPENCODE_GO_API_KEY/)
    assert.match(cleared, /OTHER_KEY: keep-me/)
  } finally {
    await rm(home, { recursive: true, force: true })
  }
})

test('credentials.mjs refuses a document it cannot trust instead of rewriting it', async () => {
  const home = await mkdtemp(join(tmpdir(), 'credentials-bad-'))
  try {
    const path = join(home, '.credentials.yaml')
    await writeFile(path, 'version: 1\nrefs: [this is not a mapping\n', { mode: 0o600 })
    const result = await exec('node', [credentials, 'sync', '--home', home, '--ref', 'OPENCODE_GO_API_KEY'], {
      env: { ...process.env, DSH_VALUE: 'sk-secret-value' },
    }).then(
      () => ({ code: 0, out: '' }),
      (error) => ({ code: error.code, out: String(error.stderr) }),
    )
    assert.equal(result.code, 2)
    assert.match(result.out, /not valid YAML/)
    assert.equal(await readFile(path, 'utf8'), 'version: 1\nrefs: [this is not a mapping\n')
  } finally {
    await rm(home, { recursive: true, force: true })
  }
})

test('a corrupt workspace registry is a failure with the recovery named', async () => {
  const dir = await fixture()
  try {
    const storages = join(dir, 'data', 'home', 'storages')
    await mkdir(storages, { recursive: true })
    await writeFile(join(storages, 'workspace.json'), '{"tables": [broken\n')
    const { code, out } = await run(['--dir', dir, '--mode', 'docker'])
    assert.equal(code, 1)
    assert.match(out, /fail\s+registry\s+the workspace registry does not parse/)
    assert.match(out, /backups\/self-\*\.tgz/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('a workspace whose directory vanished is a warning, not a failure', async () => {
  const dir = await fixture()
  try {
    const storages = join(dir, 'data', 'home', 'storages')
    await mkdir(storages, { recursive: true })
    await writeFile(join(storages, 'workspace.json'), JSON.stringify({
      tables: { workspaces: { a: { path: join(dir, 'not-there') } } },
    }))
    const { code, out } = await run(['--dir', dir, '--mode', 'docker'])
    assert.equal(code, 0, out)
    assert.match(out, /warn\s+registry\s+1 workspace\(s\), 1 with a missing directory/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})
