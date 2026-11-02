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

import { readFile, writeFile } from 'node:fs/promises'
import { basename } from 'node:path'

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

/** Strip a trailing /api/rpc or slash so callers may paste any form of the URL. */
export function normalizeBase(url) {
  return url.replace(/\/+$/, '').replace(/\/api\/rpc$/, '')
}

export function createClient({ url, token, fetchImpl = globalThis.fetch }) {
  if (typeof url !== 'string' || url.length === 0) throw new UsageError('PENPOT_API_URL is not set')
  if (typeof token !== 'string' || token.length === 0) throw new UsageError('PENPOT_ACCESS_TOKEN is not set')
  const base = normalizeBase(url)
  const headers = { authorization: `Token ${token}` }

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
    async search(query) {
      return (await rpc('search-files', { 'search-term': query })).json()
    },
    async summary(fileId) {
      return (await rpc('get-file-summary', { id: fileId })).json()
    },
    async exportBinfile(fileId) {
      const response = await rpc('export-binfile', { fileId, includeLibraries: false, embedAssets: true })
      return new Uint8Array(await response.arrayBuffer())
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
      return response.json()
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
      printList(await client.search(positional[0]), json, 'files')
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

const isMain = process.argv[1] !== undefined && process.argv[1].endsWith('penpot.mjs')
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
