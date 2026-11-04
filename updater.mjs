#!/usr/bin/env node
/**
 * Privileged update sidecar.
 *
 * Slice 1: validates an update request against the release-tag policy and
 * exposes the contract on the internal ops network. It deliberately does not
 * touch Docker yet; the apply path is added in slice 2.
 *
 * POST /update   compatible | available | exact
 * GET  /status
 * GET  /health
 */
import { execFile, spawn } from 'node:child_process'
import { randomUUID, timingSafeEqual } from 'node:crypto'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import http from 'node:http'
import { join } from 'node:path'
import { promisify } from 'node:util'

const exec = promisify(execFile)
const TAG_RE = /^v(.+)-(\d+)\.(\d+)\.(\d+)$/

export class UpdateError extends Error {
  constructor(status, message) {
    super(message)
    this.status = status
  }
}

export const parseTag = (tag) => {
  const match = TAG_RE.exec(tag)
  if (match === null) return undefined
  const [, dsh, major, minor, patch] = match
  if (!/^\d+\.\d+\.\d+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$/.test(dsh)) return undefined
  return { tag, dsh, major: Number(major), minor: Number(minor), patch: Number(patch) }
}

export async function currentTag(repo) {
  try {
    const { stdout } = await exec('git', ['describe', '--tags', '--exact-match'], { cwd: repo })
    return stdout.trim()
  } catch {
    return undefined
  }
}

export async function fetchTags(repo) {
  await exec('git', ['fetch', '--tags', '--quiet', 'origin'], { cwd: repo })
}

export async function listTags(repo) {
  const { stdout } = await exec(
    'git',
    ['-c', 'versionsort.suffix=-rc', 'tag', '--list', 'v*', '--sort=v:refname'],
    { cwd: repo },
  )
  return stdout.split('\n').map((line) => line.trim()).filter((line) => TAG_RE.test(line))
}

/**
 * The network ufw wants ("allow from 10.0.0.0/8"), from `addr/prefix`.
 *
 * The hint has to be copy-pasteable: `192.168.2.98/24` is a host address and
 * ufw would either reject it or accept something nobody meant, so the network
 * is computed here.
 */
export function networkOf(cidr) {
  const [ip, rawPrefix] = String(cidr).split('/')
  const parts = ip.split('.').map(Number)
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return cidr
  let prefix = Number(rawPrefix)
  if (!Number.isInteger(prefix) || prefix < 8 || prefix > 32) prefix = 24
  const value = ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0
  const mask = prefix === 32 ? 0xffffffff : ((0xffffffff << (32 - prefix)) >>> 0)
  const net = (value & mask) >>> 0
  return `${(net >>> 24) & 255}.${(net >>> 16) & 255}.${(net >>> 8) & 255}.${net & 255}/${prefix}`
}

/**
 * What the deployment's firewall looks like, from values the caller read: no
 * I/O here, so the shape is testable without a host that has ufw.
 */
export function firewallPorts({ ports = [], status = '' } = {}) {
  const served = ports.filter((entry) => Number.isInteger(entry.port) && typeof entry.bind === 'string'
    && !/^(127\.|localhost$|::1$)/.test(entry.bind))
  if (served.length === 0) return { applicable: false, reason: 'no LAN-facing ports' }
  if (status === '') return { applicable: false, reason: 'ufw is not installed' }
  if (!/^Status: active/m.test(status)) return { applicable: false, reason: 'ufw is not active' }
  const allowed = new Set([...status.matchAll(/^(\d+)(?:\/tcp)?\s+ALLOW/gm)].map((match) => Number(match[1])))
  return {
    applicable: true,
    ports: served.map(({ port, bind }) => ({
      port,
      bind,
      network: networkOf(bind.includes('/') ? bind : `${bind}/24`),
      allowed: allowed.has(port),
    })),
  }
}

/**
 * Pure target resolution. `tags` must be oldest-first (git's version sort).
 * Modes:
 *   compatible: latest tag with the same DSH part and product major
 *   available:  latest tag overall
 *   exact:      the named tag, not older than the current one
 */
/** Whether moving from `current` to `target` crosses a DSH line or a major. */
export function crossesCompat(current, target) {
  const from = parseTag(current)
  const to = parseTag(target)
  if (from === undefined || to === undefined) return true
  return from.dsh !== to.dsh || from.major !== to.major
}

export function resolveTarget(current, tags, { mode, version } = {}) {
  const at = tags.indexOf(current)
  if (at < 0) throw new UpdateError(422, `current tag ${current} is not in the tag list`)
  const currentParsed = parseTag(current)
  if (currentParsed === undefined) throw new UpdateError(422, `current tag ${current} is not an aligned release tag`)

  const after = tags.slice(at + 1)
  if (mode === 'available') {
    if (after.length === 0) throw new UpdateError(422, 'no newer tag')
    return after[after.length - 1]
  }
  if (mode === 'exact') {
    if (typeof version !== 'string' || version.length === 0) throw new UpdateError(400, 'exact mode needs "version"')
    const wanted = version.startsWith('v') ? version : `v${version}`
    const index = tags.indexOf(wanted)
    if (index < 0) throw new UpdateError(422, `unknown tag ${wanted}`)
    if (index <= at) throw new UpdateError(422, `${wanted} is not newer than ${current}`)
    return wanted
  }
  if (mode === 'compatible' || mode === undefined) {
    const compatible = after.filter((tag) => {
      const parsed = parseTag(tag)
      return parsed !== undefined && parsed.dsh === currentParsed.dsh && parsed.major === currentParsed.major
    })
    if (compatible.length === 0) throw new UpdateError(422, 'no compatible newer tag')
    return compatible[compatible.length - 1]
  }
  throw new UpdateError(400, `unknown mode ${String(mode)}`)
}

const authorized = (header, token) => {
  if (token.length === 0) return false
  const expected = Buffer.from(`Bearer ${token}`)
  const actual = Buffer.from(header ?? '')
  return actual.length === expected.length && timingSafeEqual(actual, expected)
}

const json = (response, status, body) => {
  response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' })
  response.end(`${JSON.stringify(body)}\n`)
}

const readBody = (request) => new Promise((resolve, reject) => {
  let size = 0
  const chunks = []
  request.on('data', (chunk) => {
    size += chunk.length
    if (size > 4096) {
      reject(new UpdateError(413, 'request body too large'))
      request.destroy()
      return
    }
    chunks.push(chunk)
  })
  request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
  request.on('error', reject)
})

/**
 * Build the request handler. The git readers are injectable so tests do not
 * need a repository; `apply` is intentionally absent in slice 1.
 */
export function createUpdater({ repo, dataDir, botToken = '', token = '', apply = false, refreshTags = async () => {}, tags = () => listTags(repo), current = () => currentTag(repo), now = Date.now, exit = (code) => process.exit(code), jobTimeoutMs = Math.max(60, Number(process.env.DSH_UPDATE_TIMEOUT_SECONDS ?? 1800)) * 1000 }) {
  const state = { job: null, child: null, timer: null }

  /**
   * Stop the running job. A build that hangs holds the only job slot forever,
   * so it gets a deadline and a way out: SIGTERM first, SIGKILL after a grace.
   */
  const killJob = (why) => {
    const child = state.child
    if (child === null || child === undefined) return false
    const signal = (name) => {
      // Negative pid: the whole process group, so a grandchild cannot outlive
      // the job and keep its output pipes open.
      try {
        if (child.pid !== undefined) process.kill(-child.pid, name)
        else child.kill(name)
      } catch {
        try {
          child.kill(name)
        } catch {
          // already gone
        }
      }
    }
    signal('SIGTERM')
    const hard = setTimeout(() => signal('SIGKILL'), 10_000)
    hard.unref?.()
    console.log(`updater: stopping the job (${why})`)
    return true
  }

  const elapsedSeconds = () => {
    const job = state.job
    if (job === null) return undefined
    const started = Date.parse(job.startedAt ?? job.acceptedAt ?? '')
    if (!Number.isFinite(started)) return undefined
    return Math.max(0, Math.round((now() - started) / 1000))
  }

  const report = async (text) => {
    if (botToken.length === 0 || dataDir === undefined) return false
    let chatId
    try {
      const bindings = JSON.parse(await readFile(join(dataDir, 'home', 'telegram-connector', 'bindings.json'), 'utf8'))
      if (typeof bindings.controlChatId === 'number') chatId = bindings.controlChatId
    } catch {
      return false
    }
    if (chatId === undefined) return false
    try {
      const body = new URLSearchParams({
        chat_id: String(chatId),
        text: text.slice(0, 3800),
        disable_web_page_preview: 'true',
      })
      const response = await globalThis.fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, { method: 'POST', body })
      if (!response.ok) console.error(`updater: Telegram report failed (${response.status})`)
      return response.ok
    } catch (error) {
      console.error(`updater: Telegram report failed: ${error instanceof Error ? error.message : String(error)}`)
      return false
    }
  }

  const persist = async () => {
    if (dataDir === undefined || state.job === null) return
    try {
      await mkdir(join(dataDir, 'update'), { recursive: true })
      await writeFile(join(dataDir, 'update', 'result.json'), `${JSON.stringify(state.job, null, 2)}
`, { mode: 0o600 })
    } catch (error) {
      console.error(`updater: cannot persist result: ${error instanceof Error ? error.message : String(error)}`)
    }
  }

  const stripAnsi = (value) => value.replace(/\x1b\[[0-9;]*m/g, '')

  const reload = () => {
    // The unit restarts the updater (Restart=always) with the checkout that was
    // just applied. Only do this once the runtime was actually stopped; a
    // failure before the stop must keep the current process for /status.
    setTimeout(() => {
      console.log('updater: exiting to reload the checkout')
      exit(0)
    }, 1000)
  }

  const runApply = async (job) => {
    let toldDown = false
    let reachedStop = false
    job.state = 'applying'
    await persist()
    let output = ''
    let child
    try {
      // --self-to enforces the compatibility policy too; this flag is the
      // updater's explicit assertion that /update already accepted the crossing.
      const args = ['update.sh', '--self-to', job.target]
      if (crossesCompat(job.from, job.target)) args.push('--i-know-versions-are-incompatible')
      child = spawn('bash', args, {
        cwd: repo,
        env: { ...process.env, PWD: repo, ASSUME_YES: '1' },
        stdio: ['ignore', 'pipe', 'pipe'],
        detached: true,
      })
    } catch (error) {
      job.state = 'failed'
      job.error = error instanceof Error ? error.message : String(error)
      await persist()
      await report(`system update failed before starting: ${job.error}`)
      return
    }
    const capture = (chunk) => {
      output = (output + chunk.toString()).slice(-20000)
      if (!toldDown && output.includes('stopping dsh')) {
        toldDown = true
        reachedStop = true
        void report('dsh is down — update in progress. New messages are queued; send them again when the bot returns.')
      }
      for (const line of chunk.toString().split('\n')) {
        if (line.includes('building dsh')) job.state = 'building'
        else if (line.includes('stopping dsh')) job.state = 'stopping'
        else if (line.includes('starting dsh')) job.state = 'starting'
      }
    }
    child.stdout.on('data', capture)
    child.stderr.on('data', capture)
    state.child = child
    state.timer = setTimeout(() => {
      job.timedOut = true
      void report(`system update is taking longer than ${String(Math.round(jobTimeoutMs / 60000))} minutes — stopping it.`)
      killJob('timed out')
    }, jobTimeoutMs)
    state.timer.unref?.()
    const code = await new Promise((resolve) => {
      child.on('error', () => resolve(-1))
      child.on('close', (value) => resolve(value ?? -1))
    })
    state.child = null
    if (state.timer !== null) {
      clearTimeout(state.timer)
      state.timer = null
    }
    const stripped = stripAnsi(output)
    const safeOutput = botToken.length > 0 ? stripped.replaceAll(botToken, '<redacted>') : stripped
    const tail = safeOutput.split('\n').filter((line) => line.trim().length > 0).slice(-20).join('\n')
    job.exitCode = code
    job.logTail = tail
    job.state = job.cancelled === true
      ? 'cancelled'
      : job.timedOut === true
        ? 'failed'
        : code === 0 ? 'done' : /rolled back/i.test(output) ? 'rolled-back' : 'failed'
    if (job.timedOut === true) job.error = `timed out after ${String(Math.round(jobTimeoutMs / 60000))} minutes`
    if (job.cancelled === true) job.error = 'cancelled'
    await persist()
    job.reporting = true
    await persist()
    let delivered = false
    if (job.state === 'cancelled') {
      delivered = await report(`system update cancelled after ${String(elapsedSeconds() ?? 0)}s. Check the updater log; the previous setup is usually still running.`)
    } else if (job.timedOut === true) {
      delivered = await report(`system update timed out after ${String(Math.round(jobTimeoutMs / 60000))} minutes and was stopped. Check the updater log; the previous state may still be running.`)
    } else if (job.state === 'done') {
      const dsh = parseTag(job.target)?.dsh ?? 'unknown'
      delivered = await report(`system update finished: ${job.from} → ${job.target} (DSH ${dsh}).${await firewallNote()}`)
    } else if (job.state === 'rolled-back') {
      delivered = await report(`system update failed and rolled back to ${job.from}.\n\n${tail}`)
    } else {
      delivered = await report(`system update failed (exit ${code}). Check the updater log; the previous state may still be running.\n\n${tail}`)
    }
    job.reporting = false
    job.reported = delivered
    await persist()
    if (reachedStop) reload()
  }

  const readComponents = async () => {
    try {
      const parsed = JSON.parse(await readFile(join(repo, 'components.json'), 'utf8'))
      return parsed.components ?? {}
    } catch {
      return {}
    }
  }

  const readFlag = async (flag) => {
    if (typeof flag !== 'string' || flag.length === 0) return undefined
    try {
      const text = await readFile(join(repo, '.env'), 'utf8')
      const match = new RegExp('^' + flag + '=([^\\n]*)', 'm').exec(text)
      return match?.[1]?.trim()
    } catch {
      return undefined
    }
  }

  const componentPort = async (component) => {
    const key = component?.config?.port?.env
    if (typeof key !== 'string' || key.length === 0) return undefined
    const value = await readFlag(key)
    const port = Number(value ?? component.config.port.default)
    return Number.isInteger(port) ? port : undefined
  }

  const runComponent = async (job) => {
    job.state = 'applying'
    const args = ['update.sh', '--component', job.component, job.action]
    if (job.port !== undefined) args.push('--port', String(job.port))
    let output = ''
    let child
    try {
      child = spawn('bash', args, { cwd: repo, env: { ...process.env, PWD: repo, ASSUME_YES: '1' }, stdio: ['ignore', 'pipe', 'pipe'], detached: true })
    } catch (error) {
      job.state = 'failed'
      job.error = error instanceof Error ? error.message : String(error)
      await report(`component ${job.component}: ${job.action} failed before starting`)
      return
    }
    const capture = (chunk) => { output = (output + chunk.toString()).slice(-8000) }
    child.stdout.on('data', capture)
    child.stderr.on('data', capture)
    state.child = child
    state.timer = setTimeout(() => {
      job.timedOut = true
      void report(`component ${job.component}: ${job.action} is taking longer than ${String(Math.round(jobTimeoutMs / 60000))} minutes — stopping it.`)
      killJob('timed out')
    }, jobTimeoutMs)
    state.timer.unref?.()
    const code = await new Promise((resolve) => {
      child.on('error', () => resolve(-1))
      child.on('close', (value) => resolve(value ?? -1))
    })
    state.child = null
    if (state.timer !== null) {
      clearTimeout(state.timer)
      state.timer = null
    }
    const stripped = stripAnsi(output)
    const safe = botToken.length > 0 ? stripped.replaceAll(botToken, '<redacted>') : stripped
    const tail = safe.split('\n').filter((line) => line.trim().length > 0).slice(-12).join('\n')
    job.exitCode = code
    job.logTail = tail
    job.state = job.cancelled === true ? 'cancelled' : code === 0 ? 'done' : 'failed'
    if (job.cancelled === true) job.error = 'cancelled'
    const label = job.port === undefined ? job.action : `${job.action} (port ${job.port})`
    const ok = await report(job.state === 'cancelled'
      ? `component ${job.component}: ${label} cancelled.`
      : job.state === 'done'
        ? `component ${job.component}: ${label} — done.`
        : `component ${job.component}: ${label} failed (exit ${code}).\n\n${tail}`)
    job.reported = ok
  }

  // --- firewall (native only) ---------------------------------------------
  // Read-only unless asked to allow one port, and then only a port this
  // deployment already serves (from .env) with a network derived from the bind
  // address: the endpoint never takes a command line.

  const ufwStatus = async () => {
    try {
      const { stdout } = await exec('ufw', ['status'])
      return stdout
    } catch {
      // "not installed", "not root", "not permitted" — nothing to offer here.
      return ''
    }
  }

  const servedPorts = async () => {
    const port = Number(await readFlag('DSH_PORT') ?? 4310)
    const bind = (await readFlag('DSH_BIND_IP') ?? '').trim()
    if (!Number.isInteger(port) || port < 1 || port > 65535 || bind === '') return []
    try {
      const { stdout } = await exec('ip', ['-o', '-4', 'addr', 'show', 'scope', 'global'])
      const line = stdout.split('\n').find((entry) => entry.includes(` ${bind}/`))
      const cidr = line?.trim().split(/\s+/)[3]
      if (cidr !== undefined && cidr.startsWith(`${bind}/`)) return [{ port, bind: cidr }]
    } catch {
      // no iproute2: fall back to /24, which networkOf still turns into a network
    }
    return [{ port, bind }]
  }

  const firewall = async () => firewallPorts({
    ports: await servedPorts(),
    status: await ufwStatus(),
  })

  /** The advisory appended to an update report, so a fix does not need SSH. */
  const firewallNote = async () => {
    const report = await firewall().catch(() => ({ applicable: false }))
    if (report.applicable !== true) return ''
    const blocked = report.ports.filter((entry) => entry.allowed === false)
    if (blocked.length === 0) return ''
    const lines = blocked.map((entry) => `• ${entry.port} from ${entry.network}: /firewall allow ${entry.port}`)
    return `\n\n⚠️ ufw blocks a port this deployment serves:\n${lines.join('\n')}`
  }

  const handler = async (request, response) => {
    const path = new URL(request.url ?? '/', 'http://updater').pathname
    try {
      if (path === '/health' && request.method === 'GET') {
        const tag = await current().catch(() => undefined)
        return json(response, 200, { ok: true, tag: tag ?? null, canApply: apply })
      }
      if (path === '/target' && request.method === 'POST') {
        if (token.length === 0) return json(response, 503, { error: 'updater is disabled (DSH_UPDATER_TOKEN is empty)' })
        if (!authorized(request.headers.authorization, token)) return json(response, 401, { error: 'unauthorized' })
        const raw = await readBody(request)
        let body
        try {
          body = raw.length === 0 ? {} : JSON.parse(raw)
        } catch {
          throw new UpdateError(400, 'body must be JSON')
        }
        try {
          await refreshTags()
        } catch (error) {
          throw new UpdateError(503, `cannot fetch release tags: ${error instanceof Error ? error.message : String(error)}`)
        }
        const from = await current()
        if (from === undefined) throw new UpdateError(409, 'checkout is not on a release tag')
        const target = resolveTarget(from, await tags(), { mode: body.mode, version: body.version })
        return json(response, 200, {
          from,
          target,
          incompatible: crossesCompat(from, target),
        })
      }
      if (path === '/update' && request.method === 'POST') {
        if (token.length === 0) return json(response, 503, { error: 'updater is disabled (DSH_UPDATER_TOKEN is empty)' })
        if (!authorized(request.headers.authorization, token)) return json(response, 401, { error: 'unauthorized' })
        if (state.job !== null && state.job.state !== 'done' && state.job.state !== 'failed' && state.job.state !== 'rolled-back') {
          return json(response, 409, { error: 'another update is running' })
        }
        const raw = await readBody(request)
        let body
        try {
          body = raw.length === 0 ? {} : JSON.parse(raw)
        } catch {
          throw new UpdateError(400, 'body must be JSON')
        }
        try {
          await refreshTags()
        } catch (error) {
          throw new UpdateError(503, `cannot fetch release tags: ${error instanceof Error ? error.message : String(error)}`)
        }
        const from = await current()
        if (from === undefined) throw new UpdateError(409, 'checkout is not on a release tag')
        const all = await tags()
        const target = resolveTarget(from, all, { mode: body.mode, version: body.version })
        // The flag is part of the contract on every path: a body cannot ask for a
        // cross-line jump by choosing "available" and skipping the check.
        if (crossesCompat(from, target) && body.incompatible !== true) {
          throw new UpdateError(
            422,
            `${target} crosses a DSH line or a product major; send "incompatible": true to allow it`,
          )
        }
        state.job = {
          id: randomUUID(),
          state: 'accepted',
          from,
          target,
          acceptedAt: new Date(now()).toISOString(),
        }
        const job = state.job
        console.log(`updater: accepted ${from} → ${target} (${String(body.mode ?? 'compatible')})`)
        json(response, 202, { job: job.id, from, target })
        if (apply) setTimeout(() => void runApply(job), 100)
        return undefined
      }
      if (path === '/components' && request.method === 'GET') {
        if (token.length === 0) return json(response, 503, { error: 'updater is disabled' })
        if (!authorized(request.headers.authorization, token)) return json(response, 401, { error: 'unauthorized' })
        const catalog = await readComponents()
        const components = []
        for (const [name, component] of Object.entries(catalog)) {
          components.push({
            name,
            label: component.label ?? name,
            description: component.description ?? '',
            enabled: (await readFlag(component.flag)) === '1',
            port: await componentPort(component),
          })
        }
        return json(response, 200, { components })
      }
      if (path === '/components' && request.method === 'POST') {
        if (token.length === 0) return json(response, 503, { error: 'updater is disabled (DSH_UPDATER_TOKEN is empty)' })
        if (!authorized(request.headers.authorization, token)) return json(response, 401, { error: 'unauthorized' })
        if (state.job !== null && state.job.state !== 'done' && state.job.state !== 'failed' && state.job.state !== 'rolled-back') {
          return json(response, 409, { error: 'another update or component change is running' })
        }
        const raw = await readBody(request)
        let body
        try {
          body = raw.length === 0 ? {} : JSON.parse(raw)
        } catch {
          throw new UpdateError(400, 'body must be JSON')
        }
        const name = typeof body.name === 'string' ? body.name : ''
        const action = typeof body.action === 'string' ? body.action : 'enable'
        if (!['enable', 'disable', 'configure'].includes(action)) throw new UpdateError(400, `unknown action ${action}`)
        const catalog = await readComponents()
        const component = catalog[name]
        if (component === undefined) throw new UpdateError(422, `unknown component ${name}`)
        let port
        if (body.port !== undefined) {
          port = Number(body.port)
          const spec = component.config?.port
          if (spec === undefined) throw new UpdateError(400, `${name} has no configurable port`)
          if (!Number.isInteger(port) || port < (spec.min ?? 1024) || port > (spec.max ?? 65535)) {
            throw new UpdateError(400, `port must be an integer between ${spec.min ?? 1024} and ${spec.max ?? 65535}`)
          }
        }
        state.job = {
          id: randomUUID(),
          state: 'accepted',
          component: name,
          action,
          ...(port === undefined ? {} : { port }),
          startedAt: new Date(now()).toISOString(),
        }
        const job = state.job
        console.log(`updater: component ${name} ${action}${port === undefined ? '' : ` port=${port}`}`)
        json(response, 202, { job: job.id, component: name, action, ...(port === undefined ? {} : { port }) })
        if (apply) setTimeout(() => void runComponent(job), 100)
        return undefined
      }
      if (path === '/cancel' && request.method === 'POST') {
        if (token.length === 0) return json(response, 503, { error: 'updater is disabled' })
        if (!authorized(request.headers.authorization, token)) return json(response, 401, { error: 'unauthorized' })
        const job = state.job
        const terminal = job === null || ['done', 'failed', 'rolled-back', 'cancelled'].includes(job.state)
        if (terminal) return json(response, 409, { error: 'no update is running' })
        if (state.child === null) return json(response, 409, { error: 'the job has not started yet; try again in a moment' })
        job.cancelled = true
        const stopped = killJob('cancelled from Telegram')
        return json(response, stopped ? 202 : 409, stopped
          ? { ok: true, cancelling: job.id }
          : { error: 'the job already finished' })
      }
      if (path === '/firewall' && request.method === 'GET') {
        if (token.length === 0) return json(response, 503, { error: 'updater is disabled' })
        if (!authorized(request.headers.authorization, token)) return json(response, 401, { error: 'unauthorized' })
        return json(response, 200, await firewall())
      }
      if (path === '/firewall' && request.method === 'POST') {
        if (token.length === 0) return json(response, 503, { error: 'updater is disabled' })
        if (!authorized(request.headers.authorization, token)) return json(response, 401, { error: 'unauthorized' })
        if (!apply) return json(response, 409, { error: 'this updater may not change the host' })
        const raw = await readBody(request)
        let body
        try {
          body = raw.length === 0 ? {} : JSON.parse(raw)
        } catch {
          throw new UpdateError(400, 'body must be JSON')
        }
        const port = Number(body.port)
        const report = await firewall()
        if (report.applicable !== true) throw new UpdateError(422, report.reason)
        const target = report.ports.find((entry) => entry.port === port)
        // Only a port this deployment already serves; nothing is taken from the
        // caller but the number, and that must match .env.
        if (target === undefined) throw new UpdateError(422, `port ${port} is not one this deployment serves`)
        if (target.allowed === true) return json(response, 200, { ok: true, port, network: target.network, already: true })
        try {
          await exec('ufw', ['allow', 'from', target.network, 'to', 'any', 'port', String(port), 'proto', 'tcp'])
        } catch (error) {
          throw new UpdateError(500, `ufw refused the rule: ${error instanceof Error ? error.message : String(error)}`)
        }
        console.log(`updater: allowed ${port}/tcp from ${target.network} (requested from Telegram)`)
        return json(response, 200, { ok: true, port, network: target.network, already: false })
      }
      if (path === '/status' && request.method === 'GET') {
        if (token.length === 0) return json(response, 503, { error: 'updater is disabled' })
        if (!authorized(request.headers.authorization, token)) return json(response, 401, { error: 'unauthorized' })
        return json(response, 200, {
          job: state.job,
          elapsedSeconds: elapsedSeconds(),
          timeoutSeconds: Math.round(jobTimeoutMs / 1000),
          cancellable: state.child !== null && state.job !== null && !['done', 'failed', 'rolled-back', 'cancelled'].includes(state.job.state),
        })
      }
      return json(response, 404, { error: 'not found' })
    } catch (error) {
      if (error instanceof UpdateError) return json(response, error.status, { error: error.message })
      console.error(`updater: ${error instanceof Error ? error.message : String(error)}`)
      return json(response, 500, { error: 'internal error' })
    }
  }
  return { handler, state }
}

// --- CLI ------------------------------------------------------------------

const isCli = process.argv[1] !== undefined && process.argv[1].endsWith('updater.mjs')
if (isCli) {
  const repo = process.env.DSH_REPO_DIR ?? process.cwd()
  const dataDir = process.env.DSH_DATA_DIR
  const token = process.env.DSH_UPDATER_TOKEN ?? ''
  const botToken = process.env.DSH_TELEGRAM_BOT_TOKEN ?? ''
  const port = Number(process.env.DSH_UPDATER_PORT ?? 8787)
  // Docker mode publishes no port at all (ops network only). Native mode runs
  // on the host, so it pins the listener to loopback explicitly.
  const host = process.env.DSH_UPDATER_HOST ?? '0.0.0.0'
  const app = createUpdater({ repo, dataDir, botToken, token, apply: true, refreshTags: () => fetchTags(repo) })
  const server = http.createServer((request, response) => void app.handler(request, response))
  server.listen(port, host, () => {
    console.log(`updater: listening on ${host}:${port} for ${repo}${token.length === 0 ? ' (disabled: no token)' : ''}`)
  })
  const stop = () => server.close(() => process.exit(0))
  process.on('SIGTERM', stop)
  process.on('SIGINT', stop)
}
