#!/usr/bin/env node
/**
 * penpot — a small, dependency-free CLI for Penpot's HTTP API.
 *
 * The runtime has no browser, so "design work" means talking to Penpot's own
 * RPC endpoint with an access token. This file is deliberately thin: it wraps
 * the handful of commands an agent needs, plus a whole-file export/import
 * round-trip (the .penpot binfile) so a design can be read, edited as JSON on
 * disk, and written back without reimplementing Penpot's change format.
 *
 * Auth:   PENPOT_API_URL     e.g. http://192.168.2.50:8090  (no /api/rpc)
 *         PENPOT_ACCESS_TOKEN from Penpot: Settings -> Access tokens
 *
 * Usage:  penpot whoami
 *         penpot teams
 *         penpot projects [--team <id>]
 *         penpot files <project-id>
 *         penpot search <query>
 *         penpot summary <file-id>
 *         penpot export <file-id> <out.penpot>
 *         penpot import <in.penpot> --project <id> [--name <name>]
 *         penpot import <in.penpot> --into <file-id>        (in-place, binfile-v3)
 *
 * Exit codes: 0 ok, 1 usage/environment error, 2 the API refused the request.
 *
 * MIT-licensed like the rest of this repository. No third-party code.
 */

import { realpathSync } from 'node:fs'
import { readFile, writeFile } from 'node:fs/promises'
import { basename } from 'node:path'
import { fileURLToPath } from 'node:url'

const USAGE = `penpot <command> [options]

  whoami
  teams
  projects [--team <id>]
  files <project-id>
  search <query>
  summary <file-id>
  export <file-id> <out.penpot>
  import <in.penpot> --project <id> [--name <name>]
  import <in.penpot> --into <file-id>

Environment: PENPOT_API_URL, PENPOT_ACCESS_TOKEN
Options:     --json  machine-readable output (default is lines for a human/agent)
             --url <url>, --token <token>  override the environment`

class ApiError extends Error {
  constructor(status, detail) {
    super(`Penpot answered ${status}${detail === '' ? '' : `: ${detail}`}`)
    this.status = status
  }
}

class UsageError extends Error {}

/** Penpot's export/import answer as SSE with transit-encoded event data. */
const decodeTransit = (value) => {
  if (typeof value === 'string') {
    if (value.startsWith('~u')) return value.slice(2)
    if (value.startsWith('~:')) return value.slice(2)
    return value
  }
  if (Array.isArray(value)) return value.map(decodeTransit)
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [
        key.startsWith('~:') || key.startsWith('~#') ? key.slice(2) : key,
        decodeTransit(item),
      ]),
    )
  }
  return value
}

const readSse = async (response) => {
  const text = await response.text()
  const events = []
  for (const block of text.split(/\r?\n\r?\n/)) {
    let event = 'message'
    const data = []
    for (const line of block.split(/\r?\n/)) {
      if (line.startsWith('event:')) event = line.slice(6).trim()
      else if (line.startsWith('data:')) data.push(line.slice(5).trim())
    }
    if (data.length === 0) continue
    const raw = data.join('\n')
    let parsed = raw
    try {
      parsed = decodeTransit(JSON.parse(raw))
    } catch {}
    events.push({ event, data: parsed })
  }
  return events
}

const lastEnd = (events) => {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    if (events[index].event !== 'end') continue
    const data = events[index].data
    if (Array.isArray(data)) return data
    if (typeof data === 'string') return data
    // Transit encodes the download as {"~#uri": "..."}; decodeTransit turns the
    // key into `uri`. Older/plain answers are the bare URL string.
    if (data !== null && typeof data === 'object' && typeof data.uri === 'string') return data.uri
    return undefined
  }
  return undefined
}

/** Strip a trailing /api/rpc or slash so callers may paste any form of the URL. */
export function normalizeBase(url) {
  return url.replace(/\/+$/, '').replace(/\/api\/rpc$/, '')
}

export function createClient({ url, token, fetchImpl = globalThis.fetch }) {
  if (typeof url !== 'string' || url.length === 0) throw new UsageError('PENPOT_API_URL is not set')
  if (typeof token !== 'string' || token.length === 0) throw new UsageError('PENPOT_ACCESS_TOKEN is not set')
  const base = normalizeBase(url)
  const headers = { authorization: `Token ${token}`, accept: 'application/json' }

  const rpc = async (command, body = {}) => {
    const response = await fetchImpl(`${base}/api/rpc/command/${command}`, {
      method: 'POST',
      headers: { ...headers, 'content-type': 'application/json' },
      body: JSON.stringify(body),
    })
    if (!response.ok) {
      const text = await response.text().catch(() => '')
      throw new ApiError(response.status, text.slice(0, 300).trim())
    }
    return response
  }

  return {
    base,
    async profile() {
      return (await rpc('get-profile')).json()
    },
    async teams() {
      return (await rpc('get-teams')).json()
    },
    async projects(teamId) {
      return (await rpc(teamId === undefined ? 'get-all-projects' : 'get-projects', teamId === undefined ? {} : { 'team-id': teamId })).json()
    },
    async files(projectId) {
      return (await rpc('get-project-files', { 'project-id': projectId })).json()
    },
    async search(query, teamId) {
      if (teamId === undefined) throw new UsageError('search needs a team id (--team) or a visible team')
      return (await rpc('search-files', { 'team-id': teamId, 'search-term': query })).json()
    },
    async summary(fileId) {
      return (await rpc('get-file-summary', { id: fileId })).json()
    },
    async exportBinfile(fileId) {
      // The endpoint streams SSE and ends with the URL of the exported zip.
      const response = await rpc('export-binfile', {
        'file-id': fileId,
        'include-libraries': false,
        'embed-assets': true,
      })
      const events = await readSse(response)
      const failure = events.find((event) => event.event === 'error')
      if (failure !== undefined) throw new ApiError(200, JSON.stringify(failure.data).slice(0, 300))
      const url = lastEnd(events)
      if (typeof url !== 'string' || url.length === 0) throw new ApiError(200, 'the export finished without a download URL')
      // The export URL is an authenticated backend route; a bare GET is 401.
      const download = await fetchImpl(url, { headers: { authorization: headers.authorization } })
      if (!download.ok) throw new ApiError(download.status, `the export download failed (${String(download.status)})`)
      return new Uint8Array(await download.arrayBuffer())
    },
    async importBinfile({ name, projectId, fileId, path }) {
      const bytes = await readFile(path)
      const form = new FormData()
      if (name !== undefined) form.set('name', name)
      if (projectId !== undefined) form.set('project-id', projectId)
      if (fileId !== undefined) form.set('file-id', fileId)
      form.set('file', new Blob([bytes], { type: 'application/octet-stream' }), basename(path))
      const response = await fetchImpl(`${base}/api/rpc/command/import-binfile`, { method: 'POST', headers, body: form })
      if (!response.ok) {
        const text = await response.text().catch(() => '')
        throw new ApiError(response.status, text.slice(0, 300).trim())
      }
      const events = await readSse(response)
      const failure = events.find((event) => event.event === 'error')
      if (failure !== undefined) throw new ApiError(200, JSON.stringify(failure.data).slice(0, 300))
      const result = lastEnd(events)
      const first = Array.isArray(result) ? result[0] : result
      return { id: typeof first === 'string' ? first : undefined }
    },
  }
}

const valueOf = (args, flag) => {
  const at = args.indexOf(flag)
  return at < 0 ? undefined : args[at + 1]
}

/** Print a list of {id,name} pairs one per line; --json prints the raw payload. */
function printList(items, json, label) {
  if (json) {
    process.stdout.write(`${JSON.stringify(items, null, 2)}\n`)
    return
  }
  if (!Array.isArray(items) || items.length === 0) {
    process.stdout.write(`no ${label}\n`)
    return
  }
  for (const item of items) {
    process.stdout.write(`${String(item.id ?? '')}\t${String(item.name ?? item.fullname ?? '')}\n`)
  }
}

export async function main(argv, io = { out: process.stdout.write.bind(process.stdout), err: process.stderr.write.bind(process.stderr) }) {
  const args = argv.slice()
  const json = args.includes('--json')
  const cleaned = args.filter((arg) => arg !== '--json')
  const [command, ...rest] = cleaned
  if (command === undefined || command === '--help' || command === '-h') {
    io.out(`${USAGE}\n`)
    return 0
  }

  const client = createClient({
    url: valueOf(rest, '--url') ?? process.env.PENPOT_API_URL,
    token: valueOf(rest, '--token') ?? process.env.PENPOT_ACCESS_TOKEN,
  })
  const positional = rest.filter((arg, index) => {
    if (arg === '--url' || arg === '--token' || arg === '--team' || arg === '--project' || arg === '--name' || arg === '--into') return false
    const previous = rest[index - 1]
    return previous !== '--url' && previous !== '--token' && previous !== '--team' && previous !== '--project' && previous !== '--name' && previous !== '--into'
  })

  switch (command) {
    case 'whoami': {
      const profile = await client.profile()
      io.out(json ? `${JSON.stringify(profile, null, 2)}\n` : `${profile.id}\t${profile.email}\n`)
      return 0
    }
    case 'teams':
      printList(await client.teams(), json, 'teams')
      return 0
    case 'projects': {
      const projects = await client.projects(valueOf(rest, '--team'))
      printList(projects, json, 'projects')
      return 0
    }
    case 'files': {
      if (positional[0] === undefined) throw new UsageError('files needs a project id')
      printList(await client.files(positional[0]), json, 'files')
      return 0
    }
    case 'search': {
      if (positional[0] === undefined) throw new UsageError('search needs a term')
      const teamId = valueOf(rest, '--team') ?? (await client.teams())[0]?.id
      if (teamId === undefined) throw new UsageError('search needs a team: no team is visible to this account')
      printList(await client.search(positional[0], teamId), json, 'files')
      return 0
    }
    case 'summary': {
      if (positional[0] === undefined) throw new UsageError('summary needs a file id')
      const summary = await client.summary(positional[0])
      io.out(`${JSON.stringify(summary, null, 2)}\n`)
      return 0
    }
    case 'export': {
      if (positional[0] === undefined || positional[1] === undefined) throw new UsageError('export needs <file-id> <out.penpot>')
      const bytes = await client.exportBinfile(positional[0])
      await writeFile(positional[1], bytes)
      io.out(`${positional[1]}\t${bytes.byteLength} bytes\n`)
      return 0
    }
    case 'import': {
      const path = positional[0]
      if (path === undefined) throw new UsageError('import needs a .penpot file')
      const result = await client.importBinfile({
        path,
        name: valueOf(rest, '--name'),
        projectId: valueOf(rest, '--project'),
        fileId: valueOf(rest, '--into'),
      })
      if (json) {
        io.out(`${JSON.stringify(result, null, 2)}\n`)
      } else {
        const id = result?.id ?? result?.['file-id'] ?? result?.file?.id ?? ''
        io.out(`imported\t${String(id)}\n`)
      }
      return 0
    }
    default:
      throw new UsageError(`unknown command: ${command}`)
  }
}

const isMain = (() => {
  if (process.argv[1] === undefined) return false
  try {
    // /usr/local/bin/penpot is a symlink to this file; compare real paths so
    // the CLI also runs through the launcher.
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))
  } catch {
    return false
  }
})()
if (isMain) {
  try {
    process.exitCode = await main(process.argv.slice(2))
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    process.stderr.write(`penpot: ${message}\n`)
    if (error instanceof UsageError) process.stderr.write(`${USAGE}\n`)
    process.exitCode = error instanceof ApiError ? 2 : 1
  }
}
