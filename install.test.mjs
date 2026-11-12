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
import { copyFile, cp, mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const here = dirname(fileURLToPath(import.meta.url))
const exec = promisify(execFile)

/** Run the installer, returning status and output instead of throwing. */
async function install(args, { env = {}, cwd = here } = {}) {
  // A --check without an explicit directory would read the developer's live
  // deployment. Give it a scratch one so the suite is host-independent.
  const hasTarget = args.some((arg) => arg === '--dir' || arg.startsWith('--dir=') || arg === '--config' || arg.startsWith('--config='))
  const scratch = (args.includes('--check') || args.includes('--uninstall')) && !hasTarget
    ? await mkdtemp(join(tmpdir(), 'install-scratch-'))
    : undefined
  const command = args.includes('--uninstall') ? 'uninstall'
    : args.includes('--doctor') ? 'doctor'
    : args.includes('--status') ? 'status'
    : 'install'
  const cleaned = args.filter((arg) => !['--uninstall', '--doctor', '--status'].includes(arg))
  const argv = scratch === undefined ? cleaned : [...cleaned, '--dir', scratch]
  try {
    // The test process may itself be running under the deployment (the agent's
    // shell inherits the service environment). Strip every deployment key so a
    // test cannot silently read the live DESIGN/CONTAINERS/ALLOWED_USER_IDS.
    const merged = { ...process.env }
    for (const key of [
      'DIR', 'SERVICE_USER', 'DESIGN', 'CONTAINERS', 'DSH_DESIGN_ENABLED',
      'PENPOT_ENABLED', 'PENPOT_API_URL', 'PENPOT_PLUGIN_REF', 'PENPOT_ACCESS_TOKEN',
      'DSH_SETUP_VERSION', 'DSH_PORT', 'DSH_BIND_IP', 'DSH_PUBLIC_URL',
      'DSH_PROVIDER', 'DSH_MODEL', 'DSH_RESOURCE_PERCENT', 'DSH_TELEGRAM_BOT_TOKEN',
      'ALLOWED_USER_IDS', 'DSH_ADMIN_USER_ID', 'DSH_UPDATER_TOKEN',
      'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_PROVIDER', 'GIT_TOKEN',
      'GIT_HOST', 'GIT_AUTH', 'GIT_KEY', 'GIT_KNOWN_HOSTS', 'GIT_PROFILES_FILE',
      'PROVIDER_KEY', 'DSH_TELEGRAM_PUBLISHER_TOKENS',
    ]) delete merged[key]
    for (const [key, value] of Object.entries(env)) {
      if (value === undefined) delete merged[key]
      else merged[key] = value
    }
    const { stdout, stderr } = await exec('bash', [join(here, 'setup.sh'), command, ...argv], {
      cwd,
      env: merged,
    })
    return { code: 0, out: stdout + stderr }
  } catch (error) {
    return { code: error.code ?? 1, out: String(error.stdout ?? '') + String(error.stderr ?? '') }
  } finally {
    if (scratch !== undefined) await rm(scratch, { recursive: true, force: true })
  }
}

test('the plan names the directory, the version and the runtime', async () => {
  const root = await mkdtemp(join(tmpdir(), 'install-plan-'))
  try {
    const { code, out } = await install(['--check', '--yes', '--dir', join(root, 'deploy')])
    assert.equal(code, 0)
    assert.match(out, /directory:\s+\S+deploy/)
  const version = (await readFile(join(here, 'VERSION'), 'utf8')).trim()
  const dsh = version.replace(/-\d+\.\d+\.\d+$/, '')
  assert.ok(out.includes(`version:   ${version} (DSH ${dsh})`), 'the plan reports the repo VERSION')
  assert.match(out, /containers:\s+podman \(rootless\)/)
  assert.match(out, /user:\s+dsh/)
  assert.match(out, /data:\s+\S+deploy\/data\/home/)
  assert.match(out, /updater:\s+http:\/\/127\.0\.0\.1:8787/)
  assert.match(out, /resources:\s+30% of this machine/)
  assert.match(out, /check only — nothing was changed/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('--check never needs root and never creates the deployment directory', async () => {
  const root = await mkdtemp(join(tmpdir(), 'install-check-'))
  const target = join(root, 'deploy')
  try {
    const { code, out } = await install(['--check', '--dir', target, '--yes'])
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
    await writeFile(config, 'DIR=/srv/other\nDSH_PORT=4477\nCONTAINERS=none\nDSH_RESOURCE_PERCENT=0\n')
    const { code, out } = await install(['--check', '--config', config])
    assert.equal(code, 0)
    assert.match(out, /directory:\s+\/srv\/other/)
    assert.match(out, /web:\s+http:\/\/\S+:4477\//)
    assert.match(out, /containers:\s+none/)
    assert.match(out, /resources:\s+unlimited/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('a config file cannot smuggle in an unknown key', async () => {
  const root = await mkdtemp(join(tmpdir(), 'install-badkey-'))
  const config = join(root, 'answers.env')
  try {
    await writeFile(config, 'PATH=/evil\n')
    const { code, out } = await install(['--check', '--config', config])
    assert.notEqual(code, 0)
    assert.match(out, /unknown key in .*answers\.env: PATH/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

// --- firewall advisory ----------------------------------------------------
// ufw gates a native service and never gates a published Docker port, so the
// plan names the exact firewall rule the updater would run.

/** Stub `ufw` (and `sudo`, which may not be installed for the test user). */
async function withUfw(statusText, fn) {
  const bin = await mkdtemp(join(here, '.ufw-bin-'))
  try {
    await writeFile(join(bin, 'ufw'), `#!/bin/sh\ncat <<'EOF'\n${statusText}\nEOF\n`, { mode: 0o755 })
    await writeFile(join(bin, 'sudo'), '#!/bin/sh\nshift\nexec "$@"\n', { mode: 0o755 })
    return await fn({ PATH: `${bin}:${process.env.PATH}` })
  } finally {
    await rm(bin, { recursive: true, force: true })
  }
}

const ufwEnv = { DSH_BIND_IP: '192.168.2.98', DSH_PORT: '4310' }
const ufwOpen = 'Status: active\n22/tcp                     ALLOW       192.168.2.0/24'
const ufwAllow = 'Status: active\n4310/tcp                   ALLOW       192.168.2.0/24'

test('native plan names the ufw rule when the port is not allowed', async () => {
  await withUfw(ufwOpen, async (env) => {
    const { code, out } = await install(['--check', '--yes'], { env: { ...env, ...ufwEnv } })
    assert.equal(code, 0)
    assert.match(out, /ufw is active and does not allow the ports this deployment serves/)
    assert.match(out, /sudo ufw allow from 192\.168\.2\.0\/24 to any port 4310 proto tcp/)
  })
})

test('native plan stays quiet when ufw already allows the port', async () => {
  await withUfw(ufwAllow, async (env) => {
    const { code, out } = await install(['--check', '--yes'], { env: { ...env, ...ufwEnv } })
    assert.equal(code, 0)
    assert.doesNotMatch(out, /ufw is active/)
  })
})

// --- update.sh, mode-aware ------------------------------------------------

/** A throwaway deployment directory with just enough for update.sh --status. */
async function deploy() {
  const dir = await mkdtemp(join(tmpdir(), 'update-status-'))
  const version = (await readFile(join(here, 'VERSION'), 'utf8')).trim()
  await cp(join(here, 'setup.sh'), join(dir, 'setup.sh'))
  await writeFile(join(dir, 'VERSION'), `${version}\n`)
  await writeFile(join(dir, '.env'), 'DSH_PORT=4310\nDSH_BIND_IP=127.0.0.1\n')
  return dir
}

test('update.sh reports the services and the installed versions', async () => {
  const dir = await deploy()
  try {
    const { stdout } = await exec('bash', [join(dir, 'setup.sh'), 'status'], { timeout: 20000 })
    assert.match(stdout, /setup version\s+\S+/)
    assert.match(stdout, /dsh version\s+\S+/)
    assert.match(stdout, /service\s+/)
    assert.match(stdout, /updater\s+/)
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

test('update.sh --to applies natively: checkout, env, restart, health gate', async (t) => {
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
    await cp(join(here, 'setup.sh'), join(dir, 'setup.sh'))
    await writeFile(join(dir, 'VERSION'), '0.2.1-rc.2-0.1.18\n')
    await writeFile(join(dir, '.env'), 'DSH_PORT=4310\nDSH_BIND_IP=127.0.0.1\n')
    await writeFile(join(dir, 'data'), '')
    await rm(join(dir, 'data'))
    await mkdir(join(dir, 'data', 'home'), { recursive: true })
    await mkdir(join(dir, 'data', 'supervisor'), { recursive: true })
    await writeFile(join(dir, 'data', 'home', 'profile.txt'), 'stable')
    await mkdir(bins, { recursive: true })
    await stub(bins, 'dsh-entrypoint', `echo "entrypoint $*" >> ${log}`)

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

    const { stdout } = await exec('bash', [join(dir, 'setup.sh'), 'update', '--to', 'v0.2.1-rc.2-0.1.19', '--yes'], {
      env: { ...process.env, PATH: `${bins}:${process.env.PATH}`, DSH_ENTRYPOINT: join(bins, 'dsh-entrypoint') },
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
  assert.match(off.out, /design:\s+none \(re-run with --design penpot to add it later\)/)

  const on = await install(['--check', '--design', 'penpot', '--yes'])
  assert.equal(on.code, 0)
  assert.match(on.out, /design:\s+Penpot on http:\/\/\S+:8090\//)

})

test('an unknown design value is refused', async () => {
  const { code, out } = await install(['--check', '--design', 'maybe', '--yes'])
  assert.notEqual(code, 0)
  assert.match(out, /--design must be penpot or none/)
})

// --- component actions, validation only (Docker does the rest) -------------

test('update.sh --component validates the registry, the action and the port', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'update-component-'))
  try {
    await cp(join(here, 'setup.sh'), join(dir, 'setup.sh'))
    await cp(join(here, 'components.json'), join(dir, 'components.json'))
    await mkdir(join(dir, 'design'), { recursive: true })
    await cp(join(here, 'design', '.env.example'), join(dir, 'design', '.env.example'))
    await writeFile(join(dir, 'VERSION'), '0.2.1-rc.2-0.3.1\n')
    await writeFile(join(dir, '.env'), 'DSH_BIND_IP=127.0.0.1\n')

    const run = async (args) => {
      try {
        const { stdout, stderr } = await exec('bash', [join(dir, 'setup.sh'), ...args], { timeout: 20000 })
        return { code: 0, out: stdout + stderr }
      } catch (error) {
        return { code: error.code ?? 1, out: String(error.stdout ?? '') + String(error.stderr ?? '') }
      }
    }

    const unknown = await run(['components', 'enable', 'nope'])
    assert.notEqual(unknown.code, 0)
    assert.match(unknown.out, /unknown component: nope/)

    const badAction = await run(['components', 'explode', 'design'])
    assert.notEqual(badAction.code, 0)
    assert.match(badAction.out, /unknown action: explode/)

    const badPort = await run(['components', 'port', 'design', '80'])
    assert.notEqual(badPort.code, 0)
    assert.match(badPort.out, /port must be between 1024 and 65535/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

// --- component apply, with Docker stubbed ---------------------------------

test('components enable starts the stack and wires the runtime without restarting it', async () => {
  const outer = await mkdtemp(join(tmpdir(), 'component-apply-'))
  const dir = join(outer, 'repo')
  const bins = join(outer, 'bin')
  const calls = join(outer, 'docker.log')
  await mkdir(dir, { recursive: true })
  if (!(await canExec(outer))) {
    await rm(outer, { recursive: true, force: true })
    return
  }
  try {
    await cp(join(here, 'setup.sh'), join(dir, 'setup.sh'))
    await cp(join(here, 'components.json'), join(dir, 'components.json'))
    await cp(join(here, 'plugins.json'), join(dir, 'plugins.json'))
    await mkdir(join(dir, 'design'), { recursive: true })
    await cp(join(here, 'design', '.env.example'), join(dir, 'design', '.env.example'))
    await writeFile(join(dir, 'VERSION'), '0.2.1-rc.2-0.4.0\n')
    await writeFile(join(dir, '.env'), 'DSH_BIND_IP=127.0.0.1\n')

    await mkdir(bins, { recursive: true })
    await stub(bins, 'podman-compose', `echo "podman-compose $*" >> ${calls}; exit 0`)
    await stub(bins, 'curl', 'printf 200')
    await stub(bins, 'systemctl', `echo "systemctl $*" >> ${calls}; exit 0`)

    const run = (args) => exec('bash', [join(dir, 'setup.sh'), ...args], {
      cwd: dir,
      env: { ...process.env, PATH: `${bins}:${process.env.PATH}` },
      timeout: 30000,
    })

    await run(['components', 'enable', 'design', '8091'])
    const designEnv = await readFile(join(dir, 'design', '.env'), 'utf8')
    const mainEnv = await readFile(join(dir, '.env'), 'utf8')
    const log = await readFile(calls, 'utf8')

    assert.match(designEnv, /DSH_DESIGN_PORT=8091/)
    assert.match(designEnv, /DSH_BIND_IP=127\.0\.0\.1/)
    assert.doesNotMatch(designEnv, /PENPOT_SECRET_KEY=change-me/)
    assert.match(mainEnv, /DSH_DESIGN_ENABLED=1/)
    assert.match(mainEnv, /PENPOT_ENABLED=1/)
    assert.match(mainEnv, /PENPOT_PLUGIN_REF=dsh-penpot-plugin@\d+\.\d+\.\d+/)
    assert.match(mainEnv, /PENPOT_API_URL=http:\/\/127\.0\.0\.1:8091/)
    assert.match(log, /podman-compose -f compose\.yaml up -d/)
    assert.doesNotMatch(log, /systemctl restart dsh/)

    await run(['components', 'disable', 'design'])
    const after = await readFile(join(dir, '.env'), 'utf8')
    const log2 = await readFile(calls, 'utf8')
    assert.match(after, /DSH_DESIGN_ENABLED=0/)
    assert.match(after, /PENPOT_ENABLED=0/)
    assert.match(log2, /podman-compose -f compose\.yaml down/)
  } finally {
    await rm(outer, { recursive: true, force: true })
  }
})

test('components enable works standalone, with no DSH deployment', async () => {
  const outer = await mkdtemp(join(tmpdir(), 'component-standalone-'))
  const dir = join(outer, 'design-only')
  const bins = join(outer, 'bin')
  const calls = join(outer, 'docker.log')
  await mkdir(dir, { recursive: true })
  if (!(await canExec(outer))) { await rm(outer, { recursive: true, force: true }); return }
  try {
    await cp(join(here, 'setup.sh'), join(dir, 'setup.sh'))
    await cp(join(here, 'components.json'), join(dir, 'components.json'))
    await cp(join(here, 'plugins.json'), join(dir, 'plugins.json'))
    await mkdir(join(dir, 'design'), { recursive: true })
    await cp(join(here, 'design', '.env.example'), join(dir, 'design', '.env.example'))
    await writeFile(join(dir, 'VERSION'), '0.2.1-rc.2-0.4.3\n')
    // No .env at all: this is a design stack without a DSH deployment.
    await mkdir(bins, { recursive: true })
    await stub(bins, 'podman-compose', `echo "podman-compose $*" >> ${calls}; exit 0`)
    await stub(bins, 'curl', 'printf 200')
    await stub(bins, 'systemctl', `echo "systemctl $*" >> ${calls}; exit 0`)

    const { stdout } = await exec('bash', [join(dir, 'setup.sh'), 'components', '--dir', dir, '--bind', '192.168.2.98', 'enable', 'design'], {
      env: { ...process.env, PATH: `${bins}:${process.env.PATH}` },
      timeout: 30000,
    })
    const designEnv = await readFile(join(dir, 'design', '.env'), 'utf8')
    const log = await readFile(calls, 'utf8')
    assert.match(designEnv, /DSH_DESIGN_PORT=8090/)
    assert.match(designEnv, /DSH_BIND_IP=192\.168\.2\.98/)
    assert.match(stdout, /standalone; no DSH deployment/)
    assert.doesNotMatch(log, /systemctl restart dsh/)
    await assert.rejects(stat(join(dir, '.env')), 'standalone design must not create a DSH .env')
  } finally {
    await rm(outer, { recursive: true, force: true })
  }
})

test('enabling the design stack mirrors a stored Penpot token into both env files', async () => {
  const outer = await mkdtemp(join(tmpdir(), 'component-token-'))
  const dir = join(outer, 'repo')
  const bins = join(outer, 'bin')
  await mkdir(dir, { recursive: true })
  if (!(await canExec(outer))) { await rm(outer, { recursive: true, force: true }); return }
  try {
    await cp(join(here, 'setup.sh'), join(dir, 'setup.sh'))
    await cp(join(here, 'components.json'), join(dir, 'components.json'))
    await cp(join(here, 'plugins.json'), join(dir, 'plugins.json'))
    await mkdir(join(dir, 'design'), { recursive: true })
    await writeFile(join(dir, 'design', '.env'), 'PENPOT_DB_PASSWORD=x\nPENPOT_SECRET_KEY=y\nPENPOT_ACCESS_TOKEN=stored-token\n')
    await writeFile(join(dir, 'VERSION'), '0.2.1-rc.2-0.4.0\n')
    await writeFile(join(dir, '.env'), 'DSH_BIND_IP=127.0.0.1\n')
    await mkdir(bins, { recursive: true })
    await stub(bins, 'podman-compose', 'exit 0')
    await stub(bins, 'curl', 'printf 200')
    await stub(bins, 'systemctl', 'exit 0')

    await exec('bash', [join(dir, 'setup.sh'), 'components', 'enable', 'design', '8095'], {
      cwd: dir,
      env: { ...process.env, PATH: `${bins}:${process.env.PATH}` },
      timeout: 30000,
    })
    const designEnv = await readFile(join(dir, 'design', '.env'), 'utf8')
    const mainEnv = await readFile(join(dir, '.env'), 'utf8')
    assert.match(designEnv, /PENPOT_ACCESS_TOKEN=stored-token/)
    assert.match(mainEnv, /PENPOT_ACCESS_TOKEN=stored-token/)
  } finally {
    await rm(outer, { recursive: true, force: true })
  }
})

test('configuring a stopped stack saves the port and does not start it', async () => {
  const outer = await mkdtemp(join(tmpdir(), 'component-config-'))
  const dir = join(outer, 'repo')
  const bins = join(outer, 'bin')
  const calls = join(outer, 'docker.log')
  await mkdir(dir, { recursive: true })
  if (!(await canExec(outer))) { await rm(outer, { recursive: true, force: true }); return }
  try {
    await cp(join(here, 'setup.sh'), join(dir, 'setup.sh'))
    await cp(join(here, 'components.json'), join(dir, 'components.json'))
    await mkdir(join(dir, 'design'), { recursive: true })
    await cp(join(here, 'design', '.env.example'), join(dir, 'design', '.env.example'))
    await writeFile(join(dir, 'VERSION'), '0.2.1-rc.2-0.4.3\n')
    await writeFile(join(dir, '.env'), 'DSH_BIND_IP=127.0.0.1\nDSH_DESIGN_ENABLED=0\n')
    await mkdir(bins, { recursive: true })
    // `ps -q` prints nothing: nothing is running.
    await stub(bins, 'podman-compose', `echo "podman-compose $*" >> ${calls}; exit 0`)
    await stub(bins, 'curl', 'printf 200')

    const { stdout } = await exec('bash', [join(dir, 'setup.sh'), 'components', 'configure', 'design', '8093'], {
      env: { ...process.env, PATH: `${bins}:${process.env.PATH}` },
      timeout: 30000,
    })
    const designEnv = await readFile(join(dir, 'design', '.env'), 'utf8')
    const mainEnv = await readFile(join(dir, '.env'), 'utf8')
    const log = await readFile(calls, 'utf8')

    assert.match(stdout, /not running; port 8093 saved/)
    assert.match(designEnv, /DSH_DESIGN_PORT=8093/)
    assert.doesNotMatch(log, / up -d/)
    assert.doesNotMatch(log, / restart dsh/)
    assert.match(mainEnv, /DSH_DESIGN_ENABLED=0/)
  } finally {
    await rm(outer, { recursive: true, force: true })
  }
})

test('configuring a running stack recreates it on the new port', async () => {
  const outer = await mkdtemp(join(tmpdir(), 'component-config-run-'))
  const dir = join(outer, 'repo')
  const bins = join(outer, 'bin')
  const calls = join(outer, 'docker.log')
  await mkdir(dir, { recursive: true })
  if (!(await canExec(outer))) { await rm(outer, { recursive: true, force: true }); return }
  try {
    await cp(join(here, 'setup.sh'), join(dir, 'setup.sh'))
    await cp(join(here, 'components.json'), join(dir, 'components.json'))
    await mkdir(join(dir, 'design'), { recursive: true })
    await cp(join(here, 'design', '.env.example'), join(dir, 'design', '.env.example'))
    await writeFile(join(dir, 'VERSION'), '0.2.1-rc.2-0.4.3\n')
    await writeFile(join(dir, '.env'), 'DSH_BIND_IP=127.0.0.1\nDSH_DESIGN_ENABLED=1\n')
    await mkdir(bins, { recursive: true })
    // `ps -q` prints a container id: something is running.
    await stub(bins, 'podman-compose', `echo "podman-compose $*" >> ${calls}; case "$*" in *"ps -q"*) echo abc123 ;; esac; exit 0`)
    await stub(bins, 'curl', 'printf 200')

    const { stdout } = await exec('bash', [join(dir, 'setup.sh'), 'components', 'configure', 'design', '8094'], {
      env: { ...process.env, PATH: `${bins}:${process.env.PATH}` },
      timeout: 30000,
    })
    const log = await readFile(calls, 'utf8')
    const mainEnv = await readFile(join(dir, '.env'), 'utf8')

    assert.match(stdout, /starting design on 127\.0\.0\.1:8094/)
    assert.match(log, / up -d/)
    // the runtime is restarted by systemd so the new PENPOT_API_URL lands
    assert.match(mainEnv, /PENPOT_API_URL=http:\/\/127\.0\.0\.1:8094/)
  } finally {
    await rm(outer, { recursive: true, force: true })
  }
})

test('a component whose probe never answers is still considered applied', async () => {
  const outer = await mkdtemp(join(tmpdir(), 'component-probe-'))
  const dir = join(outer, 'repo')
  const bins = join(outer, 'bin')
  await mkdir(dir, { recursive: true })
  if (!(await canExec(outer))) { await rm(outer, { recursive: true, force: true }); return }
  try {
    await cp(join(here, 'setup.sh'), join(dir, 'setup.sh'))
    await cp(join(here, 'components.json'), join(dir, 'components.json'))
    await mkdir(join(dir, 'design'), { recursive: true })
    await cp(join(here, 'design', '.env.example'), join(dir, 'design', '.env.example'))
    await writeFile(join(dir, 'VERSION'), '0.2.1-rc.2-0.4.5\n')
    await writeFile(join(dir, '.env'), 'DSH_BIND_IP=127.0.0.1\nDSH_DESIGN_ENABLED=1\n')
    await mkdir(bins, { recursive: true })
    await stub(bins, 'podman-compose', `case "$*" in *"ps -q"*) echo abc123 ;; esac; exit 0`)
    // The probe cannot reach the service (firewall, wrong address): 000.
    await stub(bins, 'curl', 'printf 000')

    const { stdout, stderr } = await exec('bash', [join(dir, 'setup.sh'), 'components', 'enable', 'design'], {
      env: { ...process.env, PATH: `${bins}:${process.env.PATH}`, COMPONENT_HEALTH_TIMEOUT: '2' },
      timeout: 30000,
    })
    assert.match(stderr, /did not answer/)
    assert.doesNotMatch(stdout, /design is up/)
  } finally {
    await rm(outer, { recursive: true, force: true })
  }
})

test('--uninstall --check prints what it would remove and touches nothing', async () => {
  const result = await install(['--uninstall', '--check', '--yes'])
  assert.equal(result.code, 0, result.err)
  assert.match(result.out, /uninstall plan/)
  assert.match(result.out, /keeps:\s+.*data, .*\.env, .*backups/)
  assert.match(result.out, /check only — nothing was changed/)
})

test('--uninstall --purge --check says the data goes too', async () => {
  const result = await install(['--uninstall', '--purge', '--check', '--yes'])
  assert.equal(result.code, 0, result.err)
  assert.match(result.out, /deletes:\s+.*data, .*\.env, .*backups/)
})

test('--purge without uninstall is refused with the new command', async () => {
  const result = await install(['--purge', '--check'])
  assert.notEqual(result.code, 0)
  assert.match(result.out, /--purge moved: run \.\/setup\.sh uninstall --purge/)
})

test('--uninstall without root refuses before touching anything', async () => {
  const result = await install(['--uninstall'], { env: { CI: '1' } })
  assert.notEqual(result.code, 0)
  assert.match(result.out, /removing the systemd units needs root/)
})

test('an .env from an older release is repaired, not rejected', async () => {
  // 0.4.0-era keys: no MODE, no DESIGN, no admin id, no provider key. The
  // installer must fill the gaps from defaults and leave the file alone under
  // --check, or an upgrade dirties a working deployment.
  const dir = await mkdtemp(join(tmpdir(), 'install-old-env-'))
  try {
    const legacy = [
      'DSH_PORT=4311',
      'DSH_BIND_IP=127.0.0.1',
      'DSH_PROVIDER=opencode-go',
      'DSH_MODEL=deepseek-v4.1-flash',
      'DSH_TELEGRAM_BOT_TOKEN=1:abc',
      'ALLOWED_USER_IDS=42',
      'DSH_UPDATER_TOKEN=secret',
      '',
    ].join('\n')
    await writeFile(join(dir, '.env'), legacy)
    const before = await readFile(join(dir, '.env'), 'utf8')
    const result = await install(['--check', '--yes', '--dir', dir], {
      env: { ALLOWED_USER_IDS: undefined, DSH_ADMIN_USER_ID: undefined, DESIGN: undefined },
    })
    assert.equal(result.code, 0, result.out)
    assert.match(result.out, /web:\s+http:\/\/127\.0\.0\.1:4311\//)
    assert.match(result.out, /telegram:\s+configured/)
    assert.match(result.out, /design:\s+none/)
    assert.equal(await readFile(join(dir, '.env'), 'utf8'), before, '--check must not rewrite .env')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('--plugins ui plans UI-managed plugins', async () => {
  const root = await mkdtemp(join(tmpdir(), 'install-ui-plugins-'))
  try {
    const { code, out } = await install(['--check', '--yes', '--dir', join(root, 'deploy'), '--plugins', 'ui'])
    assert.equal(code, 0)
    assert.match(out, /plugins:\s+UI-managed/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('a lone setup.sh fetches a release and shows the full plan', async (t) => {
  // The wget case: one file, no checkout. It clones into a throwaway directory,
  // runs the real installer's --check against the requested target, and leaves
  // the target untouched.
  const lone = await mkdtemp(join(tmpdir(), 'lone-'))
  const target = join(await mkdtemp(join(tmpdir(), 'lone-target-')), 'deployment')
  try {
    await copyFile(join(here, 'setup.sh'), join(lone, 'setup.sh'))
    // A tag that exists: VERSION moves before the tag is cut, and the bootstrap
    // can only clone what the repository already has.
    const { stdout: tagList } = await exec('git', ['tag', '--sort=-v:refname'], { cwd: here })
    const tag = tagList.split('\n').map((line) => line.trim()).filter(Boolean)[0]
    if (tag === undefined) {
      // A shallow clone has no tags to bootstrap from; CI checks out with
      // fetch-depth 0, so this is a local-only situation.
      t.skip('no release tag in this checkout')
      return
    }
    const version = tag.replace(/^v/, '')
    const { stdout } = await exec('bash', ['setup.sh', '--check', '--ref', tag, '--dir', target], {
      cwd: lone,
      env: { ...process.env, DSH_SETUP_REPO: here },
      timeout: 120000,
    })
    assert.match(stdout, /the setup is not here — fetching a release first/)
    assert.match(stdout, /fetching v[^ ]+ to preview the plan/)
    assert.match(stdout, new RegExp(`version:\\s+${version.replace(/\./g, '\\.')}`))
    assert.match(stdout, /check only — nothing was changed/)
    // The preview runs in a temporary checkout: the target is not created.
    await assert.rejects(stat(target), 'the target directory must not exist')
  } finally {
    await rm(lone, { recursive: true, force: true })
    await rm(target, { recursive: true, force: true })
  }
})

test('the bootstrap help names the one-liner and its options', async () => {
  const lone = await mkdtemp(join(tmpdir(), 'lone-help-'))
  try {
    await copyFile(join(here, 'setup.sh'), join(lone, 'setup.sh'))
    const { stdout } = await exec('bash', ['setup.sh', '--help'], { cwd: lone, timeout: 30000 })
    assert.match(stdout, /wget -qO-/)
    assert.match(stdout, /--ref REF/)
    assert.match(stdout, /--no-deps/)
    assert.match(stdout, /--check/)
  } finally {
    await rm(lone, { recursive: true, force: true })
  }
})

test('the root check runs before any question, not after it', async (t) => {
  // Only meaningful where docker is not usable for this user: on a runner with
  // docker and the docker group, the installer needs no root at all.
  const dockerUsable = await exec('docker', ['info']).then(() => true).catch(() => false)
  if (dockerUsable) {
    t.skip('docker is usable here, so this install needs no root')
    return
  }
  const result = await install([])
  assert.notEqual(result.code, 0)
  assert.match(result.out, /needs root/)
  assert.doesNotMatch(result.out, /Which deployment do you want/)
})

test('publisher bots can be given at install time and are written to .env', async () => {
  // One bot has one budget; the extra senders existed only in .env.example, so a
  // native install (which starts from an empty .env) never learned about them.
  const plan = await install(['--check', '--yes'], {
    env: { DSH_TELEGRAM_BOT_TOKEN: '1:a', DSH_TELEGRAM_PUBLISHER_TOKENS: '2:b,3:c' },
  })
  assert.equal(plan.code, 0, plan.out)
  assert.match(plan.out, /bots:\s+main \+ 2 publisher\(s\)/)
})

test('the downloaded checkout is described as separate from the deployment', async () => {
  // `curl | bash` leaves a checkout behind; native mode installs elsewhere.
  const source = await readFile(join(here, 'setup.sh'), 'utf8')
  assert.match(source, /is the download, not the deployment/)
  assert.match(source, /--clean-source/)
  // and never deletes a checkout the deployment updates from
  assert.match(source, /is the source this deployment updates from/)
})

test('every variable write_env persists is initialised under set -u', async () => {
  // `set -u` plus an unset variable aborts the install at the .env write — which
  // is how DSH_ADMIN_USER_ID and later DSH_TELEGRAM_PUBLISHER_TOKENS broke the
  // unattended path while every --check run stayed green.
  const source = await readFile(join(here, 'setup.sh'), 'utf8')
  const writeEnv = source.slice(source.indexOf('write_env() {'), source.indexOf('\n}\n', source.indexOf('write_env() {')))
  const used = [...writeEnv.matchAll(/set_env ([A-Z_]+) "\$\{?([A-Z_]+)/g)]
    .filter((match) => match[1] === match[2])
    .map((match) => match[1])
  assert.ok(used.length > 0, 'no set_env calls found')
  const initialised = new Set(
    [...source.matchAll(/^([A-Z_]+)=/gm)].map((match) => match[1]),
  )
  const missing = used.filter((name) => !initialised.has(name))
  assert.deepEqual(missing, [], `uninitialised: ${missing.join(', ')}`)
})


/** A PATH prefix whose `docker` never works, so the plan is host-independent. */
async function withoutDocker() {
  const root = process.env.DSH_TEST_TMPDIR ?? tmpdir()
  const bin = await mkdtemp(join(root, 'no-docker-'))
  const stub = join(bin, 'docker')
  await writeFile(stub, '#!/bin/sh\nexit 1\n', { mode: 0o755 })
  try {
    await exec(stub, [], { timeout: 5000 })
  } catch (error) {
    if (error.code === 'EACCES') return null
  }
  return `${bin}:${process.env.PATH}`
}

test('Podman is planned for the agent and skipped when containers are off', async () => {
  const root = await mkdtemp(join(tmpdir(), 'install-deps-'))
  try {
    const on = await install(['--check', '--yes', '--dir', join(root, 'a')])
    assert.equal(on.code, 0, on.out)
    assert.match(on.out, /· (installs podman|podman present)/)

    const off = await install(['--check', '--yes', '--containers', 'none', '--dir', join(root, 'b')])
    assert.equal(off.code, 0, off.out)
    assert.match(off.out, /podman not requested/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('the plan reports the deployed git manifest instead of "none"', async () => {
  const root = await mkdtemp(join(tmpdir(), 'install-git-manifest-'))
  try {
    const dir = join(root, 'deploy')
    await mkdir(join(dir, 'secrets', 'git'), { recursive: true })
    await writeFile(join(dir, 'secrets', 'git', 'profiles.json'), JSON.stringify({
      default: { provider: 'github', auth: 'https', token: 'secret-token' },
    }))
    const { code, out } = await install(['--check', '--yes', '--dir', dir])
    assert.equal(code, 0, out)
    assert.match(out, /git auth:\s+1 account\(s\): github\/https \(deployed manifest kept\)/)
    assert.doesNotMatch(out, /secret-token/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('a deployed publisher token is preserved and counted, never echoed', async () => {
  const root = await mkdtemp(join(tmpdir(), 'install-publishers-'))
  try {
    const dir = join(root, 'deploy')
    await mkdir(dir, { recursive: true })
    await writeFile(join(dir, '.env'), [
      'DSH_TELEGRAM_BOT_TOKEN=123:main',
      'DSH_TELEGRAM_PUBLISHER_TOKENS=456:first,789:second',
      '',
    ].join('\n'))
    const { code, out } = await install(['--check', '--yes', '--dir', dir])
    assert.equal(code, 0, out)
    assert.match(out, /bots:\s+main \+ 2 publisher\(s\)/)
    assert.doesNotMatch(out, /456:first|789:second/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('DSH_PUBLIC_URL is an accepted answer and is written to .env', async () => {
  const source = await readFile(join(here, 'setup.sh'), 'utf8')
  assert.match(source, /CONFIG_KEYS="[^"]*DSH_PUBLIC_URL/)
  assert.match(source, /set_env DSH_PUBLIC_URL "\$DSH_PUBLIC_URL"/)
})

test('the installer asks for a resource share and writes it to the unit', async () => {
  const source = await readFile(join(here, 'setup.sh'), 'utf8')
  assert.match(source, /ask DSH_RESOURCE_PERCENT .*percent of this machine \(0 = unlimited\)" 30/)
  assert.match(source, /MemoryMax=\$\{DSH_RESOURCE_PERCENT\}%/)
  assert.match(source, /CPUQuota=\$\(\(DSH_RESOURCE_PERCENT \* \$\(cpu_count\)\)\)%/)
  assert.match(source, /TasksMax=512/)
})

test('the plan names the git author and the repository access', async () => {
  const root = await mkdtemp(join(tmpdir(), 'install-git-plan-'))
  try {
    const withToken = await install(['--check', '--yes', '--dir', join(root, 'a')], {
      env: {
        GIT_AUTHOR_NAME: 'Vlad',
        GIT_AUTHOR_EMAIL: 'vlad@example.test',
        GIT_PROVIDER: 'github',
        GIT_TOKEN: 'ghp_ci',
      },
    })
    assert.equal(withToken.code, 0, withToken.out)
    assert.match(withToken.out, /git:\s+Vlad <vlad@example\.test>/)
    assert.match(withToken.out, /git auth:\s+github \(token stored in/)

    const without = await install(['--check', '--yes', '--dir', join(root, 'b')])
    assert.match(without.out, /git:\s+no author/)
    assert.match(without.out, /git auth:\s+none/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('the bootstrap text no longer advertises --tier or Docker', async () => {
  const source = await readFile(join(here, 'setup.sh'), 'utf8')
  assert.equal(source.includes('--tier'), false, '--tier has no parser branch and must not be documented')
  assert.equal(source.includes('Docker or Node'), false, 'the bootstrap summary must name Podman, not Docker')
  const usage = source.slice(source.indexOf('bootstrap_usage() {'), source.indexOf('in_bootstrap() {'))
  assert.equal(/Docker/.test(usage), false, 'the bootstrap options must not mention Docker')
})

test('the plan says what a re-run writes and what it keeps', async () => {
  const root = await mkdtemp(join(tmpdir(), 'install-writes-'))
  try {
    const { code, out } = await install(['--check', '--yes', '--dir', join(root, 'deploy')])
    assert.equal(code, 0)
    assert.match(out, /writes:\s+.*\.env/)
    assert.match(out, /keeps:\s+.*data/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('--uninstall refuses a system path even in a dry run', async () => {
  const system = await install(['--uninstall', '--check', '--dir', '/'])
  assert.notEqual(system.code, 0)
  assert.match(system.out, /refusing --dir \//)
})

test('--uninstall still plans a real deployment', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'install-deploy-'))
  try {
    await writeFile(join(dir, 'VERSION'), await readFile(join(here, 'VERSION'), 'utf8'))
    const { code, out } = await install(['--uninstall', '--check', '--dir', dir])
    assert.equal(code, 0)
    assert.match(out, /uninstall plan/)
    assert.match(out, /keeps:/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})
