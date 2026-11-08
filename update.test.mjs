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
import { readFileSync } from 'node:fs'
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
async function deployment({ env = 'DSH_PORT=4310\nDSH_BIND_IP=127.0.0.1\n', bins = {} } = {}) {
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
  await writeFile(file, `set -eu\n. "${join(here, 'setup.sh')}"\n${script}\n`)
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
    assert.equal(await source(dir, 'printf "%s" "$SERVICE_USER"'), 'dsh')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

needsExec('the docker probe uses a published LAN address when there is one', async () => {
  const dir = await deployment({ env: 'DSH_PORT=4310\nDSH_BIND_IP=192.0.2.10\n' })
  try {
    assert.equal(await source(dir, 'web_probe_url'), 'http://192.0.2.10:4310/')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

needsExec('DSH_PUBLIC_URL wins over both', async () => {
  const dir = await deployment({
    env: 'DSH_PORT=4310\nDSH_BIND_IP=127.0.0.1\nDSH_PUBLIC_URL=https://dsh.example.test/\n',
  })
  try {
    assert.equal(await source(dir, 'web_probe_url'), 'https://dsh.example.test/')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

needsExec('native mode probes the address the runtime actually bound', async () => {
  const dir = await deployment({ env: 'DSH_PORT=4310\nDSH_BIND_IP=127.0.0.1\n' })
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

/** A tagged checkout, for the update-policy tests that stop before apply. */
async function taggedDeployment() {
  const dir = await mkdtemp(join(tmpRoot, 'update-tags-'))
  await copyFile(join(here, 'setup.sh'), join(dir, 'setup.sh'))
  await writeFile(join(dir, 'VERSION'), '0.2.1-rc.2-0.4.11\n')
  await writeFile(join(dir, '.env'), [
    'DSH_PORT=4310',
    'DSH_BIND_IP=127.0.0.1',
    'DSH_SETUP_VERSION=0.2.1-rc.2-0.4.11',
    '',
  ].join('\n'))
  await mkdir(join(dir, 'data', 'home'), { recursive: true })
  await writeFile(join(dir, 'data', 'home', 'profile.txt'), 'stable\n')

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
  return { dir }
}

needsExec('--to refuses a cross-major target without the incompatibility flag', async () => {
  const { dir } = await taggedDeployment()
  try {
    const git = (...args) => exec('git', ['-C', dir, ...args])
    await writeFile(join(dir, 'VERSION'), '0.2.1-rc.2-1.0.0\n')
    await git('add', '-A')
    await git('commit', '-qm', 'major release')
    await git('tag', 'v0.2.1-rc.2-1.0.0')
    await git('checkout', '-q', '--detach', 'v0.2.1-rc.2-0.4.11')

    const failure = await exec('bash', [join(dir, 'setup.sh'), 'update', '--to', 'v0.2.1-rc.2-1.0.0'], {
      cwd: dir,
      env: { ...process.env, ASSUME_YES: '1' },
      timeout: 30000,
    }).then(() => undefined, (error) => error)
    assert.ok(failure, 'the crossing must be refused')
    assert.match(String(failure.stderr), /crosses a DSH line or a product major/)
    assert.match(String(failure.stderr), /--i-know-versions-are-incompatible/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

needsExec('the native entrypoint runs from the workspace directory', async () => {
  // `dsh` loads the .env of its working directory and refuses launch-only keys
  // there. Running prepare from the deployment directory — where .env lives, and
  // where the documented `./update.sh --apply` is executed — made every native
  // update fail with "DSH_BIND_IP … export it instead".
  const dir = await deployment({
    env: 'DSH_PORT=4310\nDSH_BIND_IP=127.0.0.1\n',
    bins: { runuser: 'while [ "$1" != "--" ]; do shift; done\nshift\nexec "$@"' },
  })
  try {
    const workspace = join(dir, 'data', 'workspace')
    await mkdir(workspace, { recursive: true })
    const out = await source(dir, 'run_as_service pwd')
    assert.equal(out, workspace)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('verify only reads the log of the current start', () => {
  // Re-reading the unit's whole journal reported a plugin failure from a
  // previous boot, so a healthy update said "verification complained".
  const source = readFileSync(join(here, 'setup.sh'), 'utf8')
  const verify = source.slice(source.indexOf('verify() {'), source.indexOf('\n}\n', source.indexOf('verify() {')))
  assert.match(verify, /systemctl show -p ActiveEnterTimestamp/)
  assert.match(verify, /journalctl -u dsh\.service --no-pager --since "\$since"/)
  assert.doesNotMatch(verify, /docker compose/)
  assert.doesNotMatch(verify, /-n 200/)
})

// --- firewall advisory ----------------------------------------------------
// Native only: ufw gates the systemd service through INPUT, and never gates a
// published Docker port (Docker DNATs it before INPUT is consulted). The hint
// names a copy-pasteable rule, and stays silent when there is nothing to fix.

needsExec('ufw_hints names the rule when ufw is active and the port is closed', async () => {
  const dir = await deployment({
    env: 'DSH_PORT=4310\nDSH_BIND_IP=192.168.2.98\n',
    bins: {
      ufw: "echo 'Status: active'; echo '22/tcp   ALLOW   192.168.2.0/24'",
      sudo: 'shift; exec "$@"',
    },
  })
  try {
    const out = await source(dir, 'ufw_hints 4310 192.168.2.98 2>&1')
    assert.match(out, /ufw is active and does not allow the ports this deployment serves/)
    assert.match(out, /sudo ufw allow from 192\.168\.2\.0\/24 to any port 4310 proto tcp/)
    assert.match(out, /ssh -L 4310:127\.0\.0\.1:4310/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

needsExec('ufw_hints stays quiet when the rule exists, ufw is inactive or the bind is loopback', async () => {
  const cases = [
    { label: 'rule exists', bins: { ufw: "echo 'Status: active'; echo '4310/tcp ALLOW 192.168.2.0/24'" }, args: '4310 192.168.2.98' },
    { label: 'ufw inactive', bins: { ufw: "echo 'Status: inactive'" }, args: '4310 192.168.2.98' },
    { label: 'loopback bind', bins: { ufw: "echo 'Status: active'" }, args: '4310 127.0.0.1' },
  ]
  for (const c of cases) {
    const dir = await deployment({
      env: 'DSH_PORT=4310\nDSH_BIND_IP=127.0.0.1\n',
      bins: { sudo: 'shift; exec "$@"', ...c.bins },
    })
    try {
      const out = await source(dir, `ufw_hints ${c.args} 2>&1`)
      assert.equal(out, '', `${c.label}: expected no hint, got: ${out}`)
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  }
})

needsExec('--check resolves the target without applying it', async () => {
  const { dir } = await taggedDeployment()
  try {
    const result = await exec('bash', [join(dir, 'setup.sh'), 'update', '--check'], { cwd: dir, env: { ...process.env } })
      .then((r) => ({ code: 0, out: r.stdout + r.stderr }), (error) => ({ code: error.code ?? 1, out: String(error.stdout ?? '') + String(error.stderr ?? '') }))
    assert.equal(result.code, 2, 'a newer compatible tag exits 2')
    assert.match(result.out, /target tag:\s+v0\.2\.1-rc\.2-0\.5\.0/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('the Penpot token is a stored answer, never a prompt', async () => {
  const source = await readFile(join(here, 'setup.sh'), 'utf8')
  assert.doesNotMatch(source, /ask_penpot_token/)
  assert.match(source, /PENPOT_ACCESS_TOKEN/)
})

test('--help works without a deployment and exits 0', async () => {
  const result = await exec('bash', [join(here, 'setup.sh'), 'help', 'update'])
    .then((r) => ({ code: 0, out: r.stdout + r.stderr }), (error) => ({ code: error.code ?? 1, out: String(error.stdout ?? '') + String(error.stderr ?? '') }))
  assert.equal(result.code, 0)
  assert.match(result.out, /Exit codes:/)
  assert.match(result.out, /2 {2}a newer tag exists/)
})

test('the apply prompt defaults to yes', async () => {
  const source = await readFile(join(here, 'setup.sh'), 'utf8')
  assert.match(source, /apply\? \[Y\/n\]/)
  assert.doesNotMatch(source, /apply\? \[y\/N\]/)
})
