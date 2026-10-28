#!/usr/bin/env node
/**
 * Runtime supervisor for the DSH container.
 *
 * Today the container runs `entrypoint → dsh` directly, so a plugin that breaks
 * startup leaves no way back except SSH. This process sits between them:
 *
 *   tini (PID 1) → entrypoint → supervisor → dsh
 *
 * It owns three things the in-process plugin cannot:
 *
 *   * a "stable" snapshot of the profile directory, taken at boot and refreshed
 *     whenever a change is committed;
 *   * a trial window: restart into the current (possibly broken) state, and if
 *     the connector does not confirm within the window, put the snapshot back
 *     and restart;
 *   * the restart itself, so a process that cannot boot can still be replaced.
 *
 * The connector talks to it over loopback HTTP, authenticated with a bearer
 * token. Nothing here is reachable from the LAN.
 *
 * Recovery rules:
 *   - the trial runtime exits (bad plugin, crash)      → rollback immediately
 *   - the trial runtime is up but never arms (no bot)  → rollback after boot grace
 *   - the deadline passes without /confirm             → rollback
 *   - the container restarts mid-trial                 → keep it if the deadline
 *     is still ahead, otherwise roll back before starting
 *
 * The rollback is a directory swap: the snapshot is copied to a staging path,
 * the profile is renamed aside, the copy is renamed into place, and the old
 * profile is removed. It needs no network and no package manager.
 */

import { spawn } from 'node:child_process'
import { randomUUID, timingSafeEqual } from 'node:crypto'
import { createServer } from 'node:http'
import { cp, mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

const env = process.env
const stateDir = env.DSH_SUPERVISOR_STATE ?? '/data/supervisor'
const profileDir = env.DSH_SUPERVISOR_PROFILE ?? join(env.DSH_HOME ?? '/data/home', 'profiles', 'web')
const port = Number(env.DSH_SUPERVISOR_PORT ?? 8469)
const token = env.DSH_SUPERVISOR_TOKEN ?? ''
const trialSeconds = Math.max(5, Number(env.DSH_TRIAL_SECONDS ?? 300))
const bootGraceMs = Math.max(1, Number(env.DSH_BOOT_GRACE_SECONDS ?? 120)) * 1000
const stopGraceMs = Math.max(1, Number(env.DSH_STOP_GRACE_SECONDS ?? 15)) * 1000
const entrypoint = env.DSH_ENTRYPOINT ?? '/usr/local/bin/dsh-entrypoint'
const updateTimeoutMs = Math.max(60, Number(env.DSH_UPDATE_TIMEOUT_SECONDS ?? 900)) * 1000

const args = process.argv.slice(2)
const childCommand = args[0] === '--' ? args.slice(1) : args

const stableDir = join(stateDir, 'stable')
const staging = join(stateDir, 'restore.tmp')
const stateFile = join(stateDir, 'state.json')

/** @typedef {{ id: string, startedAt: number, deadline: number | null, armed: boolean }} Trial */

let state = {
  /** @type {Trial | null} */
  trial: null,
  /** @type {number | null} */
  stableAt: null,
  /** @type {{ kind: string, at: number, detail?: string } | null} */
  lastEvent: null,
}

let child
let childExit
let stopping = false
let suppressExit = false
let busy = false
let bootTimer
let restartDelay = 1000

const now = () => Date.now()
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const log = (...parts) => console.log('[supervisor]', ...parts)

if (token.length === 0) {
  console.error('[supervisor] DSH_SUPERVISOR_TOKEN is empty; refusing to expose an unauthenticated control socket')
  process.exit(2)
}
if (childCommand.length === 0) {
  console.error('[supervisor] usage: supervisor.mjs -- <command> [args...]')
  process.exit(2)
}

async function exists(path) {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}

async function saveState() {
  const body = JSON.stringify({ ...state, savedAt: now() }, null, 2)
  const temporary = `${stateFile}.tmp`
  await writeFile(temporary, body)
  await rename(temporary, stateFile)
}

async function loadState() {
  try {
    const parsed = JSON.parse(await readFile(stateFile, 'utf8'))
    state.trial = parsed.trial ?? null
    state.stableAt = parsed.stableAt ?? null
    state.lastEvent = parsed.lastEvent ?? null
  } catch {
    // no state yet: a fresh container
  }
}

/** Copy a directory tree, replacing the destination. */
async function copyTree(source, destination) {
  await rm(destination, { recursive: true, force: true })
  await mkdir(join(destination, '..'), { recursive: true })
  await cp(source, destination, { recursive: true, force: true, preserveTimestamps: true })
}

/** Record the current profile as the state a rollback returns to. */
async function snapshotStable(reason) {
  if (!await exists(profileDir)) throw new Error(`profile directory is missing: ${profileDir}`)
  const stagingStable = join(stateDir, 'stable.tmp')
  await copyTree(profileDir, stagingStable)
  await rm(stableDir, { recursive: true, force: true })
  await rename(stagingStable, stableDir)
  state.stableAt = now()
  await saveState()
  log(`stable snapshot refreshed (${reason})`)
}

/**
 * Put the snapshot back, swapping directories rather than deleting in place:
 * a failed copy must leave the profile untouched.
 */
async function restoreStable() {
  if (!await exists(stableDir)) throw new Error('no stable snapshot to restore')
  await copyTree(stableDir, staging)
  const retired = `${profileDir}.rollback-${now()}`
  const hadProfile = await exists(profileDir)
  if (hadProfile) await rename(profileDir, retired)
  try {
    await rename(staging, profileDir)
  } catch (error) {
    if (hadProfile) await rename(retired, profileDir).catch(() => {})
    throw error
  }
  if (hadProfile) await rm(retired, { recursive: true, force: true }).catch(() => {})
  log('profile restored from the stable snapshot')
}

function startChild() {
  log(`starting: ${childCommand.join(' ')}`)
  child = spawn(childCommand[0], childCommand.slice(1), { stdio: 'inherit', env })
  childExit = new Promise((resolve) => {
    child.once('exit', (code, signal) => resolve({ code, signal }))
  })
  child.once('error', (error) => {
    console.error(`[supervisor] cannot start the runtime: ${String(error)}`)
    void onExit(null, null)
  })
  child.once('exit', (code, signal) => {
    void onExit(code, signal)
  })
}

async function stopChild() {
  if (child === undefined) return
  const current = child
  suppressExit = true
  log('stopping the runtime')
  current.kill('SIGTERM')
  const stopped = await Promise.race([childExit, delay(stopGraceMs).then(() => 'timeout')])
  if (stopped === 'timeout' && current.exitCode === null) {
    log('the runtime ignored SIGTERM; killing it')
    current.kill('SIGKILL')
    await Promise.race([childExit, delay(5000)])
  }
  suppressExit = false
  child = undefined
}

function armBootTimer() {
  clearTimeout(bootTimer)
  bootTimer = setTimeout(() => {
    if (state.trial !== null && !state.trial.armed) {
      void rollback(`the connector did not come up within ${Math.round(bootGraceMs / 1000)}s`)
    }
  }, bootGraceMs)
}

async function restartChild(kind) {
  if (busy) return
  busy = true
  try {
    await stopChild()
    startChild()
    if (kind === 'trial') armBootTimer()
  } finally {
    busy = false
  }
}

async function onExit(code, signal) {
  if (stopping || suppressExit) return
  child = undefined
  log(`runtime exited (code ${String(code)}, signal ${String(signal)})`)
  if (state.trial !== null) {
    await rollback(`the runtime exited during the trial (code ${String(code)}${signal === null ? '' : `, ${signal}`})`)
    return
  }
  restartDelay = Math.min(restartDelay * 2, 15000)
  log(`restarting in ${restartDelay}ms`)
  setTimeout(() => {
    if (!stopping && state.trial === null && child === undefined) startChild()
  }, restartDelay)
}

async function rollback(reason) {
  if (busy) return
  busy = true
  try {
    clearTimeout(bootTimer)
    log(`rolling back: ${reason}`)
    await stopChild()
    try {
      await restoreStable()
    } catch (error) {
      log(`rollback failed: ${String(error)}`)
      state.lastEvent = { kind: 'rollback-failed', at: now(), detail: `${reason}: ${String(error)}` }
      state.trial = null
      await saveState()
      startChild()
      await notify(`Rollback failed (${String(error)}). The runtime is starting with the current files; check the container logs.`)
      return
    }
    state.trial = null
    state.lastEvent = { kind: 'rollback', at: now(), detail: reason }
    await saveState()
    startChild()
    await notify(`Rolled back to the last committed state: ${reason}. The runtime is starting again.`)
  } finally {
    busy = false
  }
}

async function commit() {
  if (busy) return { ok: false, code: 409, error: 'another operation is running' }
  if (state.trial === null) return { ok: false, code: 409, error: 'no trial is running' }
  busy = true
  try {
    clearTimeout(bootTimer)
    await snapshotStable('commit')
    state.trial = null
    state.lastEvent = { kind: 'commit', at: now() }
    await saveState()
    return { ok: true }
  } catch (error) {
    return { ok: false, code: 500, error: String(error) }
  } finally {
    busy = false
  }
}

function arm() {
  if (state.trial === null) return { ok: false, code: 409, error: 'no trial is running' }
  if (child === undefined || child.exitCode !== null) {
    return { ok: false, code: 503, error: 'the runtime is not running' }
  }
  const first = !state.trial.armed
  if (first) {
    state.trial.armed = true
    state.trial.deadline = now() + trialSeconds * 1000
    clearTimeout(bootTimer)
    void saveState()
    log(`trial armed; deadline ${new Date(state.trial.deadline).toISOString()}`)
  }
  return {
    ok: true,
    firstArm: first,
    trialId: state.trial.id,
    deadline: state.trial.deadline,
    trialSeconds,
  }
}

async function beginTrial() {
  if (busy) return { ok: false, code: 409, error: 'another operation is running' }
  if (state.trial !== null) return { ok: false, code: 409, error: 'a trial is already running' }
  if (!await exists(stableDir)) {
    return { ok: false, code: 409, error: 'no committed state to roll back to; restart once from the host to record one' }
  }
  state.trial = { id: randomUUID(), startedAt: now(), deadline: null, armed: false }
  state.lastEvent = { kind: 'trial', at: now() }
  await saveState()
  const trial = state.trial
  // Answer the HTTP request before the runtime disappears with the connection.
  setTimeout(() => void restartChild('trial'), 500)
  return { ok: true, trial }
}

/**
 * Open a trial without restarting: HMR already applied the change and the
 * runtime is healthy, but the change still needs a rollback point and a
 * deadline. Commit, rollback, crash and expiry behave exactly as in a restart
 * trial.
 */
async function beginLiveTrial() {
  if (busy) return { ok: false, code: 409, error: 'another operation is running' }
  if (state.trial !== null) return { ok: false, code: 409, error: 'a trial is already running' }
  if (!await exists(stableDir)) {
    return { ok: false, code: 409, error: 'no committed state to roll back to; restart once from the host to record one' }
  }
  if (child === undefined || child.exitCode !== null) {
    return { ok: false, code: 503, error: 'the runtime is not running' }
  }
  clearTimeout(bootTimer)
  state.trial = { id: randomUUID(), startedAt: now(), deadline: now() + trialSeconds * 1000, armed: true }
  state.lastEvent = { kind: 'trial', at: now() }
  await saveState()
  log(`live trial opened; deadline ${new Date(state.trial.deadline).toISOString()}`)
  return { ok: true, trial: { ...state.trial } }
}

/** Close a trial without restoring: the change did not land, or the manager undid it. */
async function abandonTrial() {
  if (state.trial === null) return { ok: false, code: 409, error: 'no trial is running' }
  clearTimeout(bootTimer)
  state.trial = null
  state.lastEvent = { kind: 'abandon', at: now() }
  await saveState()
  log('trial abandoned; profile left as it is')
  return { ok: true }
}

/** Run a command, keep the tail of its output, and give up after a deadline. */
function runProcess(command, args, timeoutMs) {
  return new Promise((resolve) => {
    const proc = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'], env })
    let output = ''
    const capture = (chunk) => {
      const text = String(chunk)
      output = (output + text).slice(-20000)
      process.stdout.write(text)
    }
    proc.stdout.on('data', capture)
    proc.stderr.on('data', capture)
    const timer = setTimeout(() => {
      proc.kill('SIGKILL')
      output += `\n[supervisor] timed out after ${Math.round(timeoutMs / 1000)}s\n`
    }, timeoutMs)
    proc.on('error', (error) => {
      clearTimeout(timer)
      resolve({ code: -1, output: `${output}\n${String(error)}` })
    })
    proc.on('exit', (code, signal) => {
      clearTimeout(timer)
      resolve({ code: code ?? -1, signal, output })
    })
  })
}

/**
 * Reinstall the connector while the runtime is stopped. This reuses the
 * entrypoint's own reset-plugin path — the allow-builds and compatibility
 * handling that made the first install work — instead of reimplementing pnpm
 * from the supervisor.
 */
async function runUpdate(trial = true) {
  busy = true
  try {
    await stopChild()
    log('running the entrypoint reset-plugin')
    const result = await runProcess(entrypoint, ['reset-plugin'], updateTimeoutMs)
    if (result.code !== 0) {
      log(`update failed (code ${String(result.code)}); restoring the previous state`)
      await restoreStable().catch((error) => log(`restore failed: ${String(error)}`))
      state.trial = null
      state.lastEvent = {
        kind: 'rollback',
        at: now(),
        detail: `the update failed (code ${String(result.code)})`,
      }
      await saveState()
      startChild()
      await notify(
        `The connector update failed (code ${String(result.code)}); the previous state was restored. Check the container logs.`,
      )
      return
    }
    state.lastEvent = { kind: 'update', at: now() }
    await saveState()
    startChild()
    if (trial) {
      armBootTimer()
    } else {
      // No trial: the new state is committed as soon as it starts. A later
      // failure restarts the same files; it is the explicit "now" path.
      await snapshotStable('update').catch((error) => log(`cannot record the updated state: ${String(error)}`))
    }
  } finally {
    busy = false
  }
}

async function beginUpdate(trial = true) {
  if (busy) return { ok: false, code: 409, error: 'another operation is running' }
  if (state.trial !== null) return { ok: false, code: 409, error: 'a trial is already running' }
  if (!await exists(stableDir)) {
    return { ok: false, code: 409, error: 'no committed state to roll back to; restart once from the host to record one' }
  }
  if (child === undefined || child.exitCode !== null) {
    return { ok: false, code: 409, error: 'the runtime is not running' }
  }
  state.trial = trial ? { id: randomUUID(), startedAt: now(), deadline: null, armed: false } : null
  state.lastEvent = { kind: 'update', at: now() }
  await saveState()
  // Answer the request before the runtime goes away with the connection.
  setTimeout(() => void runUpdate(trial), 800)
  return { ok: true, ...(trial ? { trial: { ...state.trial } } : {}) }
}

async function plainRestart() {
  if (busy) return { ok: false, code: 409, error: 'another operation is running' }
  if (state.trial === null) {
    try {
      await snapshotStable('restart')
    } catch (error) {
      return { ok: false, code: 500, error: `cannot record the current state: ${String(error)}` }
    }
    // The connector announces this on the next boot, so a plain restart has a
    // visible end instead of silence.
    state.lastEvent = { kind: 'restart', at: now() }
    await saveState()
  }
  setTimeout(() => void restartChild('restart'), 500)
  return { ok: true }
}

async function notify(text) {
  const botToken = env.DSH_TELEGRAM_BOT_TOKEN
  if (botToken === undefined || botToken.length === 0) return
  const home = env.DSH_HOME ?? '/data/home'
  let chatId
  try {
    const bindings = JSON.parse(await readFile(join(home, 'telegram-connector', 'bindings.json'), 'utf8'))
    chatId = bindings.controlChatId
  } catch {
    return
  }
  if (typeof chatId !== 'number') return
  const body = text.length <= 3500 ? text : `${text.slice(0, 3499)}…`
  try {
    await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ chat_id: chatId, text: body, disable_web_page_preview: true }),
      signal: AbortSignal.timeout(10000),
    })
  } catch (error) {
    log(`telegram notice failed: ${String(error)}`)
  }
}

async function statusPayload() {
  return {
    child: child !== undefined && child.exitCode === null ? 'running' : 'stopped',
    profile: profileDir,
    stable: await exists(stableDir),
    stableAt: state.stableAt,
    trial: state.trial === null
      ? null
      : {
          id: state.trial.id,
          armed: state.trial.armed,
          startedAt: state.trial.startedAt,
          deadline: state.trial.deadline,
        },
    trialSeconds,
    lastEvent: state.lastEvent,
    now: now(),
  }
}

function authorized(request) {
  const header = request.headers.authorization ?? ''
  const expected = `Bearer ${token}`
  const left = Buffer.from(header)
  const right = Buffer.from(expected)
  return left.length === right.length && timingSafeEqual(left, right)
}

async function readJson(request) {
  const chunks = []
  let size = 0
  for await (const chunk of request) {
    size += chunk.length
    if (size > 64 * 1024) throw new Error('request body too large')
    chunks.push(chunk)
  }
  if (chunks.length === 0) return {}
  return JSON.parse(Buffer.concat(chunks).toString('utf8'))
}

function send(response, code, payload) {
  const body = JSON.stringify(payload)
  response.writeHead(code, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) })
  response.end(body)
}

const server = createServer((request, response) => {
  void (async () => {
    if (!authorized(request)) return send(response, 401, { error: 'unauthorized' })
    const path = (request.url ?? '/').split('?')[0]

    if (request.method === 'GET' && path === '/status') {
      return send(response, 200, await statusPayload())
    }
    if (request.method !== 'POST') return send(response, 404, { error: 'not found' })

    let body = {}
    try {
      body = await readJson(request)
    } catch (error) {
      return send(response, 400, { error: String(error) })
    }

    if (path === '/trial/arm') {
      const result = arm()
      return send(response, result.ok ? 200 : result.code, result)
    }
    if (path === '/update') {
      const result = await beginUpdate(body.trial !== false)
      return send(response, result.ok ? 200 : result.code, result)
    }
    if (path === '/trial/open') {
      const result = await beginLiveTrial()
      return send(response, result.ok ? 200 : result.code, result)
    }
    if (path === '/trial/abandon') {
      const result = await abandonTrial()
      return send(response, result.ok ? 200 : result.code, result)
    }
    if (path === '/trial/commit') {
      const result = await commit()
      return send(response, result.ok ? 200 : result.code, result)
    }
    if (path === '/trial/rollback') {
      if (state.trial === null) return send(response, 409, { error: 'no trial is running' })
      const reason = typeof body.reason === 'string' && body.reason.length > 0
        ? body.reason
        : 'rollback requested from Telegram'
      void rollback(reason)
      return send(response, 200, { ok: true })
    }
    if (path === '/restart') {
      const result = body.trial === true ? await beginTrial() : await plainRestart()
      return send(response, result.ok ? 200 : result.code, result)
    }
    return send(response, 404, { error: 'not found' })
  })().catch((error) => {
    log(`request failed: ${String(error)}`)
    send(response, 500, { error: String(error) })
  })
})

process.on('SIGTERM', () => { void shutdown() })
process.on('SIGINT', () => { void shutdown() })

async function shutdown() {
  if (stopping) return
  stopping = true
  clearTimeout(bootTimer)
  log('shutting down')
  await stopChild()
  await saveState().catch(() => {})
  process.exit(0)
}

async function main() {
  await mkdir(stateDir, { recursive: true })
  await loadState()

  // Restoring swaps directories, so the snapshot has to live on the same
  // filesystem as the profile; both are under /data by default.
  try {
    const [profileStat, stateStat] = await Promise.all([stat(profileDir), stat(stateDir)])
    if (profileStat.dev !== stateStat.dev) {
      log('warning: the profile and the snapshot are on different filesystems; rollback will not be able to rename the restored copy into place')
    }
  } catch {
    // the profile may not exist yet on a very first boot; the snapshot step reports it
  }

  // A trial that outlived the container must not outlive its deadline.
  if (state.trial !== null && state.trial.deadline !== null && now() >= state.trial.deadline) {
    log('trial deadline passed while the container was down; restoring before start')
    await restoreStable().catch((error) => log(`restore failed: ${String(error)}`))
    state.trial = null
    state.lastEvent = { kind: 'rollback', at: now(), detail: 'deadline passed while the container was down' }
    await saveState()
    await notify('The trial deadline passed while the container was down, so the last committed state was restored.')
  }

  if (!await exists(stableDir)) {
    await snapshotStable('boot').catch((error) => log(`cannot record the boot state: ${String(error)}`))
  }

  server.listen(port, '127.0.0.1', () => {
    log(`listening on 127.0.0.1:${port}, profile ${profileDir}`)
    if (state.trial !== null) log('a trial is still open; it resumes when the connector arms')
  })

  startChild()
  if (state.trial !== null) armBootTimer()
}

setInterval(() => {
  if (busy) return
  const trial = state.trial
  if (trial === null || trial.deadline === null) return
  if (now() >= trial.deadline) {
    void rollback(`no confirmation within ${Math.round(trialSeconds / 60)} minutes`)
  }
}, 1000)

await main()
