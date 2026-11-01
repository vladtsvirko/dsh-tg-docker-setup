/**
 * Tests for install.sh and the mode-aware update.sh.
 *
 * The installer is driven the way a user drives it — through its CLI — and the
 * assertions are on the plan it prints and on what it does *not* touch. The
 * mutating paths need root, Docker or systemd, so they are exercised on a real
 * host; the contract that matters here is that the plan is complete, the flags
 * are validated, and --check really is read-only.
 *
 *   node --test install.test.mjs
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { cp, mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const here = dirname(fileURLToPath(import.meta.url))
const exec = promisify(execFile)

/** Run the installer, returning status and output instead of throwing. */
async function install(args, { env = {}, cwd = here } = {}) {
  try {
    const { stdout, stderr } = await exec('bash', [join(here, 'install.sh'), ...args], {
      cwd,
      env: { ...process.env, ...env },
    })
    return { code: 0, out: stdout + stderr }
  } catch (error) {
    return { code: error.code ?? 1, out: String(error.stdout ?? '') + String(error.stderr ?? '') }
  }
}

test('docker plan names the mode, the directory and the version', async () => {
  const { code, out } = await install(['--check', '--mode', 'docker', '--yes'])
  assert.equal(code, 0)
  assert.match(out, /mode:\s+docker/)
  assert.match(out, /directory:\s+\S+dsh-tg-docker-setup/)
  const version = (await readFile(join(here, 'VERSION'), 'utf8')).trim()
  assert.ok(out.includes(`version:   ${version} (DSH 0.2.1-rc.2)`), 'the plan reports the repo VERSION')
  assert.match(out, /updater:\s+sidecar/)
  assert.match(out, /check only — nothing was changed/)
})

test('native plan names the tier, the service user and the data paths', async () => {
  const { code, out } = await install(['--check', '--mode', 'native', '--yes'])
  assert.equal(code, 0)
  assert.match(out, /mode:\s+native/)
  assert.match(out, /tier:\s+sandbox/)
  assert.match(out, /user:\s+dsh/)
  assert.match(out, /data:\s+\/srv\/dsh\/data\/home/)
  assert.match(out, /updater:\s+http:\/\/127\.0\.0\.1:8787/)
})

test('--check never needs root and never creates the deployment directory', async () => {
  const root = await mkdtemp(join(tmpdir(), 'install-check-'))
  const target = join(root, 'deploy')
  try {
    const { code, out } = await install(['--check', '--mode', 'native', '--dir', target, '--yes'])
    assert.equal(code, 0)
    assert.match(out, new RegExp(`directory:\\s+${target}`))
    await assert.rejects(stat(target), /ENOENT/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('answers come from a config file, without prompting', async () => {
  const root = await mkdtemp(join(tmpdir(), 'install-config-'))
  const config = join(root, 'answers.env')
  try {
    await writeFile(config, 'MODE=native\nDIR=/srv/other\nDSH_PORT=4477\nTIER=privileged\n')
    const { code, out } = await install(['--check', '--config', config])
    assert.equal(code, 0)
    assert.match(out, /mode:\s+native/)
    assert.match(out, /directory:\s+\/srv\/other/)
    assert.match(out, /web:\s+http:\/\/\S+:4477\//)
    assert.match(out, /tier:\s+privileged/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('a config file cannot smuggle in an unknown key', async () => {
  const root = await mkdtemp(join(tmpdir(), 'install-badkey-'))
  const config = join(root, 'answers.env')
  try {
    await writeFile(config, 'MODE=docker\nPATH=/evil\n')
    const { code, out } = await install(['--check', '--config', config])
    assert.notEqual(code, 0)
    assert.match(out, /unknown key in .*answers\.env: PATH/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('an unknown mode is refused', async () => {
  const { code, out } = await install(['--check', '--mode', 'podman', '--yes'])
  assert.notEqual(code, 0)
  assert.match(out, /--mode must be docker or native/)
})

test('--tier is native-only', async () => {
  const { code, out } = await install(['--check', '--mode', 'docker', '--tier', 'privileged', '--yes'])
  assert.notEqual(code, 0)
  assert.match(out, /--tier only applies to native mode/)
})

// --- update.sh, mode-aware ------------------------------------------------

/** A throwaway deployment directory with just enough for update.sh --status. */
async function deploy(mode) {
  const dir = await mkdtemp(join(tmpdir(), `update-${mode}-`))
  const version = (await readFile(join(here, 'VERSION'), 'utf8')).trim()
  await cp(join(here, 'update.sh'), join(dir, 'update.sh'))
  await writeFile(join(dir, 'VERSION'), `${version}\n`)
  await writeFile(join(dir, '.env'), `MODE=${mode}\nDSH_PORT=4310\nDSH_BIND_IP=127.0.0.1\n`)
  return dir
}

test('update.sh reports the native mode and its services', async () => {
  const dir = await deploy('native')
  try {
    const { stdout } = await exec('bash', [join(dir, 'update.sh'), '--status'], { timeout: 20000 })
    assert.match(stdout, /mode\s+native/)
    assert.match(stdout, /service\s+/)
    assert.match(stdout, /updater\s+/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('update.sh keeps the docker path when .env says docker', async () => {
  const dir = await deploy('docker')
  try {
    const { stdout } = await exec('bash', [join(dir, 'update.sh'), '--status'], { timeout: 20000 })
    assert.match(stdout, /mode\s+docker/)
    assert.match(stdout, /container\s+/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

// --- native apply, end to end with systemd stubbed ------------------------

/** Write an executable stub into dir. */
async function stub(dir, name, body) {
  await writeFile(join(dir, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 })
}

/**
 * Stubs must be executable. Docker mounts /tmp noexec, so a plain
 * `node --test` in the runtime container cannot run them; skip instead of
 * failing on an environment limit.
 */
async function canExec(dir) {
  const probe = join(dir, '.probe')
  try {
    await writeFile(probe, '#!/bin/sh\nexit 0\n', { mode: 0o755 })
    await exec(probe)
    return true
  } catch {
    return false
  }
}

test('update.sh --self-to applies natively: checkout, env, restart, health gate', async (t) => {
  // Stubs live outside the checkout: update.sh refuses a dirty tree.
  const outer = await mkdtemp(join(tmpdir(), 'update-native-apply-'))
  const dir = join(outer, 'repo')
  const bins = join(outer, 'bin')
  const log = join(outer, 'calls.log')
  await mkdir(dir, { recursive: true })
  if (!(await canExec(outer))) {
    t.skip('temp directory is noexec (run with TMPDIR on an exec-capable filesystem)')
    return
  }
  try {
    await cp(join(here, 'update.sh'), join(dir, 'update.sh'))
    await writeFile(join(dir, 'VERSION'), '0.2.1-rc.2-0.1.18\n')
    await writeFile(join(dir, '.env'), 'MODE=native\nDSH_PORT=4310\nDSH_BIND_IP=127.0.0.1\n')
    await writeFile(join(dir, 'data'), '')
    await rm(join(dir, 'data'))
    await mkdir(join(dir, 'data', 'home'), { recursive: true })
    await mkdir(join(dir, 'data', 'supervisor'), { recursive: true })
    await writeFile(join(dir, 'data', 'home', 'profile.txt'), 'stable')
    await stub(dir, 'dsh-entrypoint', `echo "entrypoint $*" >> ${log}`)

    const git = (...args) => exec('git', ['-C', dir, ...args])
    await git('init', '-q')
    // update.sh fetches tags before it resolves a target.
    await git('remote', 'add', 'origin', dir)
    await git('config', 'user.email', 'test@example.com')
    await git('config', 'user.name', 'Test')
    await git('add', '-A')
    await git('commit', '-qm', 'release 18')
    await git('tag', 'v0.2.1-rc.2-0.1.18')
    await writeFile(join(dir, 'VERSION'), '0.2.1-rc.2-0.1.19\n')
    await git('add', '-A')
    await git('commit', '-qm', 'release 19')
    await git('tag', 'v0.2.1-rc.2-0.1.19')
    // Deploy the older tag, as a running deployment would be.
    await git('checkout', '-q', '--detach', 'v0.2.1-rc.2-0.1.18')

    await mkdir(bins, { recursive: true })
    await stub(bins, 'systemctl', `echo "systemctl $*" >> ${log}; exit 0`)
    // The target keeps the same DSH part, so npm must not be called; stub it
    // anyway so a machine without a global dsh does not hit the network.
    await stub(bins, 'npm', `echo "npm $*" >> ${log}; exit 0`)
    await stub(bins, 'dsh', 'echo 0.2.1-rc.2')
    await stub(bins, 'journalctl', 'exit 0')
    await stub(bins, 'curl', 'printf 200')
    await stub(bins, 'runuser', 'while [ "$1" != "--" ]; do shift; done; shift; exec "$@"')

    const { stdout } = await exec('bash', [join(dir, 'update.sh'), '--self-to', 'v0.2.1-rc.2-0.1.19'], {
      env: { ...process.env, PATH: `${bins}:${process.env.PATH}`, ASSUME_YES: '1' },
      timeout: 30000,
    })
    const calls = await readFile(log, 'utf8')
    const env = await readFile(join(dir, '.env'), 'utf8')
    const head = (await exec('git', ['-C', dir, 'describe', '--tags', '--exact-match'])).stdout.trim()

    assert.match(stdout, /setup update: v0\.2\.1-rc\.2-0\.1\.18 → v0\.2\.1-rc\.2-0\.1\.19/)
    assert.equal(head, 'v0.2.1-rc.2-0.1.19', 'the checkout must move to the target tag')
    assert.match(env, /DSH_SETUP_VERSION=0\.2\.1-rc\.2-0\.1\.19/)
    assert.match(calls, /systemctl restart dsh\.service/)
    assert.match(calls, /entrypoint init/)
    assert.match(stdout, /done — v0\.2\.1-rc\.2-0\.1\.19 is running/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('the design stack is opt-in and named in the plan', async () => {
  const off = await install(['--check', '--yes'])
  assert.match(off.out, /design:\s+none \(re-run with --design docker to add it later\)/)

  const on = await install(['--check', '--design', 'docker', '--yes'])
  assert.equal(on.code, 0)
  assert.match(on.out, /design:\s+Penpot on http:\/\/\S+:8090\//)
  assert.match(on.out, /MCP on 127\.0\.0\.1:4401/)
})

test('an unknown design value is refused', async () => {
  const { code, out } = await install(['--check', '--design', 'maybe', '--yes'])
  assert.notEqual(code, 0)
  assert.match(out, /--design must be none or docker/)
})
