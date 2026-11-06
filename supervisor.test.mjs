/**
 * Integration tests for supervisor.mjs.
 *
 * They run the real supervisor against a fake runtime (a Node script that stays
 * alive, logs each start and exits when a flag file appears), so the snapshot,
 * swap, deadline and notify paths are exercised end to end.
 *
 *   node --test supervisor.test.mjs
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createServer } from 'node:net'
import { mkdtemp, mkdir, readFile, rm, unlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const supervisor = join(here, 'supervisor.mjs')

/**
 * The harness writes `entrypoint.sh` stubs and executes them directly, so the
 * temp directory must be mounted exec-capable. A hardened sandbox mounts /tmp
 * `noexec`, and the symptom is a 15-second timeout rather than an error, so the
 * capability is probed once and the suite skips instead of failing. Override the
 * location with `DSH_TEST_TMPDIR=/some/exec/path`.
 */
const tmpRoot = process.env.DSH_TEST_TMPDIR ?? tmpdir()

async function canExecIn(dir) {
  const probe = join(await mkdtemp(join(dir, 'exec-probe-')), 'probe.sh')
  try {
    await writeFile(probe, '#!/bin/sh\nexit 0\n', { mode: 0o755 })
    await new Promise((resolve, reject) => {
      spawn(probe, [], { stdio: 'ignore' })
        .once('error', reject)
        .once('exit', (code) => (code === 0 ? resolve() : reject(new Error(`exit ${String(code)}`))))
    })
    return true
  } catch {
    return false
  } finally {
    await rm(dirname(probe), { recursive: true, force: true })
  }
}

const execAllowed = await canExecIn(tmpRoot)

/** Skip the suite with a reason where a shell script cannot be executed. */
const needsExec = (name, fn) =>
  execAllowed
    ? test(name, fn)
    : test(name, (t) => t.skip(`temp directory ${tmpRoot} is mounted noexec; set DSH_TEST_TMPDIR`))

const fakeRuntime = `import { appendFileSync, existsSync } from 'node:fs'
if (process.env.FAKE_LOG) appendFileSync(process.env.FAKE_LOG, 'start\\n')
if (process.env.FAKE_CRASH_FILE) {
  setInterval(() => { if (existsSync(process.env.FAKE_CRASH_FILE)) process.exit(4) }, 100)
}
process.on('SIGTERM', () => process.exit(0))
setInterval(() => {}, 1000)
`

function freePort() {
  return new Promise((resolve, reject) => {
    const server = createServer()
    server.on('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port
      server.close(() => resolve(port))
    })
  })
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

async function waitFor(probe, { timeout = 10000, interval = 100, what = 'condition' } = {}) {
  const deadline = Date.now() + timeout
  for (;;) {
    const value = await probe()
    if (value) return value
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`)
    await wait(interval)
  }
}

async function harness({ trialSeconds = 60, bootGrace = 30, entryExit = 0, entrySleep = 0 } = {}) {
  const root = await mkdtemp(join(tmpRoot, 'supervisor-'))
  const profile = join(root, 'profiles', 'web')
  const state = join(root, 'state')
  const crash = join(root, 'crash')
  const log = join(root, 'child.log')
  await mkdir(profile, { recursive: true })
  await writeFile(join(profile, 'a.txt'), 'stable')
  await writeFile(join(profile, 'cordis.patch.yml'), '[]')
  const fake = join(root, 'fake-runtime.mjs')
  await writeFile(fake, fakeRuntime)
  const entry = join(root, 'entrypoint.sh')
  await writeFile(
    entry,
    `#!/bin/sh\necho entrypoint >> "$FAKE_ENTRY_LOG"\n[ -n "$DSH_PLUGIN_TARGET_REF" ] && echo "ref:$DSH_PLUGIN_TARGET_REF" >> "$FAKE_ENTRY_LOG"\necho partial > "$FAKE_ENTRY_WRITE"\ncase "$1" in reset-plugin) [ -n "$FAKE_ENTRY_SLEEP" ] && sleep "$FAKE_ENTRY_SLEEP" ;; esac\nexit ${entryExit}\n`,
    { mode: 0o755 },
  )
  const entryLog = join(root, 'entry.log')
  const entryWrite = join(profile, 'partial.txt')

  const port = await freePort()
  const token = 'test-secret'
  const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' }

  const launch = () => {
    const child = spawn(process.execPath, [supervisor, '--', process.execPath, fake], {
      env: {
        ...process.env,
        DSH_SUPERVISOR_STATE: state,
        DSH_SUPERVISOR_PROFILE: profile,
        DSH_SUPERVISOR_PORT: String(port),
        DSH_SUPERVISOR_TOKEN: token,
        DSH_TRIAL_SECONDS: String(trialSeconds),
        DSH_BOOT_GRACE_SECONDS: String(bootGrace),
        FAKE_LOG: log,
        FAKE_CRASH_FILE: crash,
        DSH_ENTRYPOINT: entry,
        FAKE_ENTRY_LOG: entryLog,
        FAKE_ENTRY_WRITE: entryWrite,
        ...(entrySleep > 0 ? { FAKE_ENTRY_SLEEP: String(entrySleep) } : {}),
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    let output = ''
    child.stdout.on('data', (chunk) => { output += chunk })
    child.stderr.on('data', (chunk) => { output += chunk })
    return {
      child,
      output: () => output,
      exited: new Promise((resolve) => child.once('exit', (code) => resolve(code))),
    }
  }

  let running = launch()
  await waitFor(() => running.output().includes('listening on'), { what: 'the supervisor to listen' })

  const call = async (path, body) => {
    const response = await fetch(`http://127.0.0.1:${port}${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    return { status: response.status, body: await response.json() }
  }

  const status = async () => (await call('/status')).body

  await waitFor(async () => {
    const value = await status()
    return value.child === 'running' && value.stable === true
  }, { what: 'the first runtime start' })

  return {
    root,
    profile,
    state,
    crash,
    log,
    port,
    entryLog,
    entryWrite,
    call,
    status,
    get output() { return running.output() },
    async restartSupervisor() {
      running.child.kill('SIGTERM')
      await running.exited
      running = launch()
      await waitFor(() => running.output().includes('listening on'), { what: 'the supervisor to listen again' })
    },
    async stop() {
      running.child.kill('SIGTERM')
      await running.exited
      await rm(root, { recursive: true, force: true })
    },
  }
}

/**
 * Start lines in the fake runtime's log. The file does not exist until the
 * child has written its first line, and "child: running" is reported as soon
 * as it is spawned — a slow runner makes that gap visible, so a missing file
 * counts as zero starts instead of failing the test.
 */
const starts = async (log) => {
  const text = await readFile(log, 'utf8').catch(() => '')
  return text.trim().split('\n').filter(Boolean).length
}

needsExec('boots with a stable snapshot and a running runtime', async () => {
  const test1 = await harness()
  try {
    const status = await test1.status()
    assert.equal(status.child, 'running')
    assert.equal(status.stable, true)
    assert.equal(status.trial, null)
    assert.equal(await readFile(join(test1.state, 'stable', 'a.txt'), 'utf8'), 'stable')
  } finally {
    await test1.stop()
  }
})

needsExec('a trial arms and commits, keeping the new state', async () => {
  const test2 = await harness()
  try {
    const before = await starts(test2.log)
    const begun = await test2.call('/restart', { trial: true })
    assert.equal(begun.status, 200)

    await waitFor(async () => (await test2.status()).trial !== null, { what: 'the trial to open' })
    await waitFor(async () => (await test2.status()).child === 'running', { what: 'the trial runtime' })
    await waitFor(async () => (await starts(test2.log)) > before, { what: 'the runtime restart' })

    const armed = await test2.call('/trial/arm', {})
    assert.equal(armed.status, 200)
    assert.equal(armed.body.firstArm, true)
    assert.ok(armed.body.deadline > Date.now())

    await writeFile(join(test2.profile, 'b.txt'), 'trial')
    const committed = await test2.call('/trial/commit', {})
    assert.equal(committed.status, 200)

    const status = await test2.status()
    assert.equal(status.trial, null)
    assert.equal(await readFile(join(test2.state, 'stable', 'b.txt'), 'utf8'), 'trial')
  } finally {
    await test2.stop()
  }
})

needsExec('rollback restores the committed state', async () => {
  const test3 = await harness()
  try {
    await test3.call('/restart', { trial: true })
    await waitFor(async () => (await test3.status()).trial !== null, { what: 'the trial to open' })
    await test3.call('/trial/arm', {})
    await writeFile(join(test3.profile, 'c.txt'), 'oops')

    const rolled = await test3.call('/trial/rollback', { reason: 'test rollback' })
    // 202: accepted and running. 200 used to mean "promised", including refusals.
    assert.equal(rolled.status, 202)
    await waitFor(async () => {
      const status = await test3.status()
      return status.trial === null && status.lastEvent?.kind === 'rollback'
    }, { what: 'the rollback to finish' })

    await assert.rejects(readFile(join(test3.profile, 'c.txt')), /ENOENT/)
    assert.equal(await readFile(join(test3.profile, 'a.txt'), 'utf8'), 'stable')
    await waitFor(async () => (await test3.status()).child === 'running', { what: 'the runtime to come back' })
  } finally {
    await test3.stop()
  }
})

needsExec('a trial that never arms rolls back after the boot grace', async () => {
  const test4 = await harness({ bootGrace: 1 })
  try {
    await test4.call('/restart', { trial: true })
    await waitFor(async () => (await test4.status()).trial !== null, { what: 'the trial to open' })
    await waitFor(async () => (await test4.status()).trial === null, { timeout: 5000, what: 'the boot grace to expire' })
    const status = await test4.status()
    assert.equal(status.lastEvent?.kind, 'rollback')
    assert.match(status.lastEvent?.detail ?? '', /did not come up/)
  } finally {
    await test4.stop()
  }
})

needsExec('a crash during the trial rolls back', async () => {
  const test5 = await harness()
  try {
    await test5.call('/restart', { trial: true })
    await waitFor(async () => (await test5.status()).trial !== null, { what: 'the trial to open' })
    await test5.call('/trial/arm', {})
    await writeFile(test5.crash, '1')

    await waitFor(async () => (await test5.status()).trial === null, { what: 'the crash rollback' })
    const status = await test5.status()
    assert.equal(status.lastEvent?.kind, 'rollback')
    assert.match(status.lastEvent?.detail ?? '', /exited during the trial/)
    await unlink(test5.crash).catch(() => {})
    await waitFor(async () => (await test5.status()).child === 'running', { timeout: 15000, what: 'the runtime to come back' })
  } finally {
    await test5.stop()
  }
})

needsExec('the deadline rolls the trial back', async () => {
  const test6 = await harness({ trialSeconds: 5 })
  try {
    await test6.call('/restart', { trial: true })
    await waitFor(async () => (await test6.status()).trial !== null, { what: 'the trial to open' })
    const armed = await test6.call('/trial/arm', {})
    assert.equal(armed.status, 200)
    await writeFile(join(test6.profile, 'd.txt'), 'late')

    await waitFor(async () => (await test6.status()).trial === null, { timeout: 12000, what: 'the deadline' })
    assert.match((await test6.status()).lastEvent?.detail ?? '', /no confirmation within/)
    await assert.rejects(readFile(join(test6.profile, 'd.txt')), /ENOENT/)
  } finally {
    await test6.stop()
  }
})

needsExec('a live trial opens without a restart and commits', async () => {
  const test11 = await harness()
  try {
    const before = await starts(test11.log)
    const opened = await test11.call('/trial/open', {})
    assert.equal(opened.status, 200)
    assert.ok(opened.body.trial.deadline > Date.now())
    assert.equal(await starts(test11.log), before)

    await writeFile(join(test11.profile, 'live.txt'), 'live')
    assert.equal((await test11.call('/trial/commit', {})).status, 200)
    assert.equal(await readFile(join(test11.state, 'stable', 'live.txt'), 'utf8'), 'live')
  } finally {
    await test11.stop()
  }
})

needsExec('a live trial can be abandoned without touching the profile', async () => {
  const test12 = await harness()
  try {
    await writeFile(join(test12.profile, 'keep.txt'), 'keep')
    assert.equal((await test12.call('/trial/open', {})).status, 200)
    assert.equal((await test12.call('/trial/abandon', {})).status, 200)
    const status = await test12.status()
    assert.equal(status.trial, null)
    assert.equal(status.lastEvent?.kind, 'abandon')
    assert.equal(await readFile(join(test12.profile, 'keep.txt'), 'utf8'), 'keep')
  } finally {
    await test12.stop()
  }
})

needsExec('a live trial rolls back on the deadline', async () => {
  const test13 = await harness({ trialSeconds: 5 })
  try {
    assert.equal((await test13.call('/trial/open', {})).status, 200)
    await writeFile(join(test13.profile, 'late.txt'), 'late')
    await waitFor(async () => (await test13.status()).trial === null, {
      timeout: 12000,
      what: 'the live deadline',
    })
    assert.match((await test13.status()).lastEvent?.detail ?? '', /no confirmation within/)
    await assert.rejects(readFile(join(test13.profile, 'late.txt')), /ENOENT/)
  } finally {
    await test13.stop()
  }
})

needsExec('a crash during a live trial rolls back', async () => {
  const test14 = await harness()
  try {
    assert.equal((await test14.call('/trial/open', {})).status, 200)
    await writeFile(join(test14.profile, 'crash.txt'), 'crash')
    await writeFile(test14.crash, '1')
    await waitFor(async () => (await test14.status()).trial === null, { what: 'the crash rollback' })
    assert.match((await test14.status()).lastEvent?.detail ?? '', /exited during the trial/)
    await unlink(test14.crash).catch(() => {})
  } finally {
    await test14.stop()
  }
})

needsExec('the trial survives a supervisor restart and can still be committed', async () => {
  const test7 = await harness()
  try {
    await test7.call('/restart', { trial: true })
    await waitFor(async () => (await test7.status()).trial !== null, { what: 'the trial to open' })
    const armed = await test7.call('/trial/arm', {})
    assert.equal(armed.status, 200)
    const deadline = armed.body.deadline

    await test7.restartSupervisor()

    const resumed = await test7.status()
    assert.notEqual(resumed.trial, null)
    assert.equal(resumed.trial.deadline, deadline)

    await waitFor(async () => (await test7.status()).child === 'running', { what: 'the resumed runtime' })
    const committed = await test7.call('/trial/commit', {})
    assert.equal(committed.status, 200)
    assert.equal((await test7.status()).trial, null)
  } finally {
    await test7.stop()
  }
})

needsExec('an update runs the entrypoint under a trial', async () => {
  const test15 = await harness()
  try {
    const before = await starts(test15.log)
    const updated = await test15.call('/update', {})
    assert.equal(updated.status, 200)
    await waitFor(async () => {
      const status = await test15.status()
      const ran = await readFile(test15.entryLog, 'utf8').catch(() => '')
      return ran.includes('entrypoint') && status.child === 'running' && status.trial !== null
    }, { timeout: 15000, what: 'the update to finish' })
    await waitFor(async () => (await starts(test15.log)) > before, { what: 'the restarted runtime to log' })
    assert.match(await readFile(test15.entryLog, 'utf8'), /entrypoint/)
    assert.equal((await test15.call('/trial/commit', {})).status, 200)
  } finally {
    await test15.stop()
  }
})

needsExec('an update passes the exact npm spec to reset-plugin', async () => {
  const testRef = await harness()
  try {
    assert.equal((await testRef.call('/update', { ref: 'dsh-telegram-connector@0.14.0' })).status, 200)
    await waitFor(async () => {
      const ran = await readFile(testRef.entryLog, 'utf8').catch(() => '')
      return ran.includes('ref:dsh-telegram-connector@0.14.0')
    }, { timeout: 15000, what: 'the ref to reach the entrypoint' })
    assert.equal((await testRef.call('/trial/commit', {})).status, 200)
  } finally {
    await testRef.stop()
  }
})

needsExec('an update with a malformed ref is refused before anything stops', async () => {
  const testBadRef = await harness()
  try {
    const response = await testBadRef.call('/update', { ref: 'github:o/r; rm -rf /' })
    assert.equal(response.status, 400)
    assert.match(response.body?.error ?? '', /invalid plugin ref/)
    assert.equal((await testBadRef.status()).child, 'running')
  } finally {
    await testBadRef.stop()
  }
})

needsExec('a failed update restores the previous state', async () => {
  const test16 = await harness({ entryExit: 1 })
  try {
    assert.equal((await test16.call('/update', {})).status, 200)
    await waitFor(async () => {
      const status = await test16.status()
      return status.trial === null && status.lastEvent?.kind === 'rollback'
    }, { timeout: 15000, what: 'the failed update to roll back' })
    assert.match((await test16.status()).lastEvent?.detail ?? '', /the update failed/)
    await assert.rejects(readFile(test16.entryWrite), /ENOENT/)
    await waitFor(async () => (await test16.status()).child === 'running', { what: 'the runtime to come back' })
  } finally {
    await test16.stop()
  }
})

needsExec('a plain restart records an event the connector can announce', async () => {
  const test10 = await harness()
  try {
    const restarted = await test10.call('/restart', { trial: false })
    assert.equal(restarted.status, 200)
    await waitFor(async () => {
      const status = await test10.status()
      return status.child === 'running' && status.lastEvent?.kind === 'restart'
    }, { what: 'the restart event' })
  } finally {
    await test10.stop()
  }
})

needsExec('rollback without a trial is refused', async () => {
  const test9 = await harness()
  try {
    const rolled = await test9.call('/trial/rollback', {})
    assert.equal(rolled.status, 409)
    assert.match(rolled.body.error, /no trial/)
  } finally {
    await test9.stop()
  }
})

needsExec('requests without the token are refused', async () => {
  const test8 = await harness()
  try {
    const response = await fetch(`http://127.0.0.1:${test8.port}/status`)
    assert.equal(response.status, 401)
    const wrong = await fetch(`http://127.0.0.1:${test8.port}/status`, {
      headers: { authorization: 'Bearer nope' },
    })
    assert.equal(wrong.status, 401)
  } finally {
    await test8.stop()
  }
})

needsExec('a rollback request while the supervisor is busy is refused, not promised', async () => {
  // A slow reset-plugin holds `busy` long enough to ask deterministically.
  const test = await harness({ entrySleep: 3 })
  try {
    const update = await test.call('/update', { trial: true })
    assert.equal(update.status, 200, JSON.stringify(update.body))
    await waitFor(async () => (await test.status()).busy === true, { what: 'the supervisor to report busy' })
    const refused = await test.call('/trial/rollback', { reason: 'test' })
    assert.equal(refused.status, 409)
    assert.match(String(refused.body.error), /another operation is running/)
    // It is still doing the work it was asked to do.
    await waitFor(async () => (await test.status()).busy === false, { timeout: 15000, what: 'the update to finish' })
    const after = await test.status()
    assert.equal(after.child, 'running')
  } finally {
    await test.stop()
  }
})

needsExec('a state write that fails does not kill the supervisor mid-rollback', async () => {
  const test = await harness()
  try {
    await test.call('/restart', { trial: true })
    await waitFor(async () => (await test.status()).trial !== null, { what: 'the trial to open' })
    // Make saveState throw while restoreStable still works: the state file's
    // path becomes a directory, so the write and the rename both fail.
    const stateFile = join(test.state, 'state.json')
    await rm(stateFile, { force: true })
    await mkdir(stateFile)
    const result = await test.call('/trial/rollback', { reason: 'test' })
    assert.equal(result.status, 202)
    // The child is already "running" when the request returns, so wait for the
    // state change instead: a rollback closes the trial before it restarts.
    await waitFor(async () => (await test.status()).trial === null, { timeout: 10000, what: 'the trial to close' })
    await waitFor(async () => (await test.status()).child === 'running', { timeout: 10000, what: 'the runtime to come back' })
    const after = await test.status()
    assert.equal(after.lastEvent?.kind, 'rollback')
    assert.equal(test.output.includes('cannot persist the rollback state'), true)
  } finally {
    await test.stop()
  }
})

needsExec('arming a trial during another operation is refused', async () => {
  const test = await harness({ entrySleep: 3 })
  try {
    const update = await test.call('/update', { trial: true })
    assert.equal(update.status, 200)
    await waitFor(async () => (await test.status()).busy === true, { what: 'the supervisor to report busy' })
    const armed = await test.call('/trial/arm', {})
    assert.equal(armed.status, 409)
    assert.match(String(armed.body.error), /another operation is running/)
    await waitFor(async () => (await test.status()).busy === false, { timeout: 15000, what: 'the update to finish' })
  } finally {
    await test.stop()
  }
})
