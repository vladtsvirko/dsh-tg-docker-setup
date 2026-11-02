/**
 * Tests for update.sh's helpers, run by sourcing the script.
 *
 * The health gate, the launcher lookup and the tag policy are the parts that
 * report "updated" or "rolled back": a wrong URL or a missing launcher made
 * every native update fail and every host-only docker update roll back. They
 * are shell functions, so the script can be sourced and the functions called
 * directly — no Docker, no root, no running deployment.
 *
 *   node --test update.test.mjs
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { spawn } from 'node:child_process'
import { chmod, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const here = dirname(fileURLToPath(import.meta.url))
const exec = promisify(execFile)

/**
 * The stubs are shell scripts that must be executable, and a hardened sandbox
 * mounts /tmp noexec. Probe once, skip with a reason, and let CI run it.
 */
const tmpRoot = process.env.DSH_TEST_TMPDIR ?? tmpdir()

async function canExecIn(dir) {
  const probe = join(await mkdtemp(join(dir, "exec-probe-")), "probe.sh")
  try {
    await writeFile(probe, "#!/bin/sh\nexit 0\n", { mode: 0o755 })
    await new Promise((resolve, reject) => {
      spawn(probe, [], { stdio: "ignore" })
        .once("error", reject)
        .once("exit", (code) => (code === 0 ? resolve() : reject(new Error("exit"))))
    })
    return true
  } catch {
    return false
  } finally {
    await rm(dirname(probe), { recursive: true, force: true })
  }
}

const execAllowed = await canExecIn(tmpRoot)
const needsExec = (name, fn) => (execAllowed
  ? test(name, fn)
  : test(name, (t) => t.skip(`temp directory ${tmpRoot} is mounted noexec; set DSH_TEST_TMPDIR`)))

/** Make a throwaway deployment directory and stub binaries for it. */
async function deployment({ env = 'MODE=docker\nDSH_PORT=4310\nDSH_BIND_IP=127.0.0.1\n', bins = {} } = {}) {
  const dir = await mkdtemp(join(tmpRoot, 'update-lib-'))
  await writeFile(join(dir, 'VERSION'), '0.2.1-rc.2-0.5.0\n')
  await writeFile(join(dir, '.env'), env)
  if (Object.keys(bins).length > 0) {
    const bin = join(dir, 'bin')
    await mkdir(bin, { recursive: true })
    for (const [name, body] of Object.entries(bins)) {
      await writeFile(join(bin, name), `#!/bin/sh\n${body}\n`)
      await chmod(join(bin, name), 0o755)
    }
  }
  return dir
}

/** Source update.sh in `dir` and run `script`; returns stdout. */
async function source(dir, script) {
  const file = join(dir, 'probe.sh')
  await writeFile(file, `set -eu\n. "${join(here, 'update.sh')}"\n${script}\n`)
  const bin = join(dir, 'bin')
  const { stdout } = await exec('bash', [file], {
    cwd: dir,
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
  })
  return stdout.trim()
}

needsExec('sourcing defines the helpers and runs no command', async () => {
  const dir = await deployment()
  try {
    // --status would print a report and exit if the CLI ran.
    assert.equal(await source(dir, 'printf "%s" "$MODE"'), 'docker')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

needsExec('the docker health probe uses the compose service when the bind is loopback', async () => {
  // The updater container's own 127.0.0.1 is not the runtime: probing it made a
  // healthy host-only update fail its health gate and roll back.
  const dir = await deployment({ env: 'MODE=docker\nDSH_PORT=4310\nDSH_BIND_IP=127.0.0.1\n' })
  try {
    assert.equal(await source(dir, 'web_probe_url'), 'http://dsh:4310/')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

needsExec('the docker probe uses a published LAN address when there is one', async () => {
  const dir = await deployment({ env: 'MODE=docker\nDSH_PORT=4310\nDSH_BIND_IP=192.0.2.10\n' })
  try {
    assert.equal(await source(dir, 'web_probe_url'), 'http://192.0.2.10:4310/')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

needsExec('DSH_PUBLIC_URL wins over both', async () => {
  const dir = await deployment({
    env: 'MODE=docker\nDSH_PORT=4310\nDSH_BIND_IP=127.0.0.1\nDSH_PUBLIC_URL=https://dsh.example.test/\n',
  })
  try {
    assert.equal(await source(dir, 'web_probe_url'), 'https://dsh.example.test/')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

needsExec('native mode probes the address the runtime actually bound', async () => {
  const dir = await deployment({ env: 'MODE=native\nDSH_PORT=4310\nDSH_BIND_IP=127.0.0.1\n' })
  try {
    assert.equal(await source(dir, 'web_probe_url'), 'http://127.0.0.1:4310/')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

needsExec('a 401 counts as serving and a dead port does not', async () => {
  const dir = await deployment({
    bins: { curl: 'printf 401' },
  })
  try {
    assert.equal(await source(dir, 'web_code'), '401')
    assert.equal(await source(dir, 'web_ready && echo ready || echo down'), 'ready')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
  const dead = await deployment({ bins: { curl: 'exit 7' } })
  try {
    assert.equal(await source(dead, 'web_code'), '000')
    assert.equal(await source(dead, 'web_ready && echo ready || echo down'), 'down')
  } finally {
    await rm(dead, { recursive: true, force: true })
  }
})

needsExec('the launcher is found where an install puts it', async () => {
  const dir = await deployment()
  try {
    // An explicit override wins (that is how the installer test names it).
    const fake = join(dir, 'launcher')
    await writeFile(fake, '#!/bin/sh\nexit 0\n')
    await chmod(fake, 0o755)
    assert.equal(await source(dir, `DSH_ENTRYPOINT="${fake}" entrypoint_bin`), fake)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

needsExec('the launcher falls back to the deployment directory', async () => {
  const dir = await deployment()
  try {
    const inRepo = join(dir, 'entrypoint.sh')
    await writeFile(inRepo, '#!/bin/sh\nexit 0\n')
    await chmod(inRepo, 0o755)
    // /usr/local/bin/dsh-entrypoint may exist on a real host; the fallback is
    // what a fresh checkout has, so accept either when the installed one exists.
    const found = await source(dir, 'entrypoint_bin || echo none')
    assert.ok(found === inRepo || found === '/usr/local/bin/dsh-entrypoint', found)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

needsExec('die returns instead of exiting when sourced', async () => {
  const dir = await deployment()
  try {
    assert.equal(await source(dir, 'die "boom" || true; echo survived'), 'survived')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

needsExec('the tag split keeps the DSH part intact', async () => {
  const dir = await deployment()
  try {
    assert.equal(await source(dir, 'tag_dsh v0.2.1-rc.2-0.5.0'), '0.2.1-rc.2')
    assert.equal(await source(dir, 'tag_product v0.2.1-rc.2-0.5.0'), '0.5.0')
    assert.equal(await source(dir, 'tag_major v0.2.1-rc.2-0.5.0'), '0')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

/**
 * The docker update path end to end, with Docker stubbed.
 *
 * This is the test that was missing when `/system update all` reported success
 * and kept the old connector: it asserts the deployed `.env` carries the new
 * version (env_file beats the image ENV), that the runtime is recreated, and
 * that a failed health gate restores both.
 */
async function dockerDeployment({ healthy = true } = {}) {
  const dir = await mkdtemp(join(tmpRoot, 'update-docker-'))
  const bin = join(dir, 'bin')
  await mkdir(bin, { recursive: true })
  const calls = join(dir, 'calls.log')
  await copyFile(join(here, 'update.sh'), join(dir, 'update.sh'))
  await writeFile(join(dir, 'VERSION'), '0.2.1-rc.2-0.4.11\n')
  await writeFile(join(dir, '.env'), [
    'MODE=docker',
    'DSH_PORT=4310',
    'DSH_BIND_IP=127.0.0.1',
    'DSH_SETUP_VERSION=0.2.1-rc.2-0.4.11',
    '',
  ].join('\n'))
  await writeFile(join(dir, 'compose.yaml'), 'services:\n  dsh:\n    image: dsh-backend:test\n')
  await writeFile(join(bin, 'docker'), [
    '#!/bin/sh',
    `echo "docker $*" >> "${calls}"`,
    'case "$*" in',
    '  *"inspect --format"*)',
    '    case "$*" in',
    `      *Health*) echo "${healthy ? 'healthy' : 'unhealthy'}" ;;`,
    '      *) echo sha256:previous ;;',
    '    esac ;;',
    '  *"ps -q"*) echo abc123 ;;',
    'esac',
    'exit 0',
    '',
  ].join('\n'))
  await writeFile(join(bin, 'curl'), '#!/bin/sh\nprintf 401\n')
  await chmod(join(bin, 'docker'), 0o755)
  // A real deployment has data/home to snapshot; without it the update aborts
  // before it can be tested.
  await mkdir(join(dir, 'data', 'home'), { recursive: true })
  await writeFile(join(dir, 'data', 'home', 'profile.txt'), 'stable\n')
  await chmod(join(bin, 'curl'), 0o755)

  const git = (...args) => exec('git', ['-C', dir, ...args])
  await git('init', '-q')
  await git('remote', 'add', 'origin', dir)
  await git('config', 'user.email', 'test@example.com')
  await git('config', 'user.name', 'Test')
  await git('add', '-A')
  await git('commit', '-qm', 'release 11')
  await git('tag', 'v0.2.1-rc.2-0.4.11')
  await writeFile(join(dir, 'VERSION'), '0.2.1-rc.2-0.5.0\n')
  await git('add', '-A')
  await git('commit', '-qm', 'release 50')
  await git('tag', 'v0.2.1-rc.2-0.5.0')
  await git('checkout', '-q', '--detach', 'v0.2.1-rc.2-0.4.11')
  return { dir, bin, calls }
}

needsExec('a docker update rewrites the deployed version before starting', async () => {
  const { dir, bin, calls } = await dockerDeployment()
  try {
    await exec('bash', [join(dir, 'update.sh'), '--self-to', 'v0.2.1-rc.2-0.5.0'], {
      cwd: dir,
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, ASSUME_YES: '1', HEALTH_TIMEOUT: '2', WEB_READY_TIMEOUT: '2' },
      timeout: 30000,
    })
    const env = await readFile(join(dir, '.env'), 'utf8')
    // Without this the entrypoint keeps installing connector#v0.4.11: compose's
    // env_file overrides the new image's ENV.
    assert.match(env, /^DSH_SETUP_VERSION=0\.2\.1-rc\.2-0\.5\.0$/m)
    const log = await readFile(calls, 'utf8')
    assert.match(log, /compose build dsh/)
    assert.match(log, /compose stop dsh/)
    assert.match(log, /compose up -d dsh/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

needsExec('a docker update that fails its health gate restores the old version', async () => {
  const { dir, bin, calls } = await dockerDeployment({ healthy: false })
  try {
    await exec('bash', [join(dir, 'update.sh'), '--self-to', 'v0.2.1-rc.2-0.5.0'], {
      cwd: dir,
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, ASSUME_YES: '1', HEALTH_TIMEOUT: '2', WEB_READY_TIMEOUT: '2' },
      timeout: 30000,
    }).catch(() => undefined)
    const env = await readFile(join(dir, '.env'), 'utf8')
    assert.match(env, /^DSH_SETUP_VERSION=0\.2\.1-rc\.2-0\.4\.11$/m)
    const log = await readFile(calls, 'utf8')
    assert.match(log, /docker tag sha256:previous/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})
