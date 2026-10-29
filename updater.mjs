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
 * Pure target resolution. `tags` must be oldest-first (git's version sort).
 * Modes:
 *   compatible: latest tag with the same DSH part and product major
 *   available:  latest tag overall
 *   exact:      the named tag, not older than the current one
 */
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
export function createUpdater({ repo, dataDir, botToken = '', token = '', apply = false, refreshTags = async () => {}, tags = () => listTags(repo), current = () => currentTag(repo), now = Date.now }) {
  const state = { job: null }

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
    // Docker's restart policy brings the container back with the new mounted
    // updater.mjs. Only do this once the runtime was actually stopped; a
    // build failure before the stop must keep the current process for /status.
    setTimeout(() => {
      console.log('updater: exiting to reload the checkout')
      process.exit(0)
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
      child = spawn('bash', ['update.sh', '--self-to', job.target], {
        cwd: repo,
        env: { ...process.env, PWD: repo, ASSUME_YES: '1' },
        stdio: ['ignore', 'pipe', 'pipe'],
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
    const code = await new Promise((resolve) => {
      child.on('error', () => resolve(-1))
      child.on('close', (value) => resolve(value ?? -1))
    })
    const stripped = stripAnsi(output)
    const safeOutput = botToken.length > 0 ? stripped.replaceAll(botToken, '<redacted>') : stripped
    const tail = safeOutput.split('\n').filter((line) => line.trim().length > 0).slice(-20).join('\n')
    job.exitCode = code
    job.logTail = tail
    job.state = code === 0 ? 'done' : /rolled back/i.test(output) ? 'rolled-back' : 'failed'
    await persist()
    job.reporting = true
    await persist()
    let delivered = false
    if (job.state === 'done') {
      const dsh = parseTag(job.target)?.dsh ?? 'unknown'
      delivered = await report(`system update finished: ${job.from} → ${job.target} (DSH ${dsh}).`)
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
        return json(response, 200, { from, target })
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
      if (path === '/status' && request.method === 'GET') {
        if (token.length === 0) return json(response, 503, { error: 'updater is disabled' })
        if (!authorized(request.headers.authorization, token)) return json(response, 401, { error: 'unauthorized' })
        return json(response, 200, { job: state.job })
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
  const app = createUpdater({ repo, dataDir, botToken, token, apply: true, refreshTags: () => fetchTags(repo) })
  const server = http.createServer((request, response) => void app.handler(request, response))
  server.listen(port, '0.0.0.0', () => {
    console.log(`updater: listening on :${port} for ${repo}${token.length === 0 ? ' (disabled: no token)' : ''}`)
  })
  const stop = () => server.close(() => process.exit(0))
  process.on('SIGTERM', stop)
  process.on('SIGINT', stop)
}
