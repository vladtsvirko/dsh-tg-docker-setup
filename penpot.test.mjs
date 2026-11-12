/**
 * Tests for design/penpot.mjs — the dependency-free Penpot CLI.
 *
 * A fake Penpot answers the RPC calls, so the request shape, the auth header,
 * the export bytes and the multipart import are all checked without a real
 * instance. What cannot be checked here (a live Penpot accepting our multipart
 * field names) is called out in docs/DESIGN.md.
 *
 *   node --test penpot.test.mjs
 */

import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import http from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { promisify } from 'node:util'
import { createClient, main, normalizeBase } from './design/penpot.mjs'

const exec = promisify(execFile)
const here = new URL('.', import.meta.url).pathname

const startFake = async (handler) => {
  const calls = []
  const server = http.createServer((request, response) => {
    let body = ''
    request.on('data', (chunk) => { body += chunk.toString('latin1') })
    request.on('end', () => {
      const call = { url: request.url, auth: request.headers.authorization, accept: request.headers.accept ?? '', type: request.headers['content-type'] ?? '', body }
      calls.push(call)
      handler(call, response)
    })
  })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  return { server, calls, base: `http://127.0.0.1:${server.address().port}` }
}

const json = (response, status, body) => {
  response.writeHead(status, { 'content-type': 'application/json' })
  response.end(JSON.stringify(body))
}

test('normalizeBase accepts a pasted URL with or without /api/rpc', () => {
  assert.equal(normalizeBase('http://host:8090'), 'http://host:8090')
  assert.equal(normalizeBase('http://host:8090/'), 'http://host:8090')
  assert.equal(normalizeBase('http://host:8090/api/rpc/'), 'http://host:8090')
})

test('whoami posts to the RPC endpoint with a token and a JSON accept header', async () => {
  const { server, base, calls } = await startFake((call, response) => {
    json(response, 200, { id: 'u1', email: 'a@b.c' })
  })
  try {
    const client = createClient({ url: `${base}/api/rpc`, token: 'tok' })
    assert.deepEqual(await client.profile(), { id: 'u1', email: 'a@b.c' })
    assert.equal(calls[0].url, '/api/rpc/command/get-profile')
    assert.equal(calls[0].auth, 'Token tok')
    assert.equal(calls[0].accept, 'application/json')
    assert.equal(calls[0].body, '{}')
  } finally {
    server.close()
  }
})

test('search scopes the request to a team', async () => {
  const { server, base, calls } = await startFake((call, response) => json(response, 200, []))
  try {
    const client = createClient({ url: base, token: 'tok' })
    await client.search('chat', 'team-1')
    assert.equal(calls[0].url, '/api/rpc/command/search-files')
    assert.deepEqual(JSON.parse(calls[0].body), { 'team-id': 'team-1', 'search-term': 'chat' })
  } finally {
    server.close()
  }
})

test('projects sends the team id in kebab-case', async () => {
  const { server, base, calls } = await startFake((call, response) => json(response, 200, []))
  try {
    const client = createClient({ url: base, token: 'tok' })
    await client.projects('team-1')
    assert.equal(calls[0].url, '/api/rpc/command/get-projects')
    assert.deepEqual(JSON.parse(calls[0].body), { 'team-id': 'team-1' })
  } finally {
    server.close()
  }
})

test('export reads the SSE download URL and fetches the zip', async () => {
  let downloadUrl = ''
  const { server, base, calls } = await startFake((call, response) => {
    if (call.url === '/download') {
      response.writeHead(200, { 'content-type': 'application/zip' })
      response.end(Buffer.from('PENPOT-BINFILE'))
      return
    }
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    response.end(['event: end', `data: ${JSON.stringify(downloadUrl)}`, ''].join('\n'))
  })
  downloadUrl = `${base}/download`
  const dir = await mkdtemp(join(tmpdir(), 'penpot-export-'))
  try {
    const out = join(dir, 'file.penpot')
    const client = createClient({ url: base, token: 'tok' })
    const bytes = await client.exportBinfile('file-1')
    await writeFile(out, bytes)
    assert.equal((await readFile(out, 'utf8')), 'PENPOT-BINFILE')
    assert.equal(calls.find((call) => call.url === '/download')?.auth, 'Token tok')
  } finally {
    server.close()
    await rm(dir, { recursive: true, force: true })
  }
})

test('export reads the transit ~#uri download map', async () => {
  let downloadUrl = ''
  const { server, base } = await startFake((call, response) => {
    if (call.url === '/download') {
      response.writeHead(200, { 'content-type': 'application/zip' })
      response.end(Buffer.from('PK-PENPOT'))
      return
    }
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    response.end(['event: end', `data: ${JSON.stringify({ '~#uri': downloadUrl })}`, ''].join('\n'))
  })
  downloadUrl = `${base}/download`
  try {
    const client = createClient({ url: base, token: 'tok' })
    assert.equal(new TextDecoder().decode(await client.exportBinfile('file-1')), 'PK-PENPOT')
  } finally {
    server.close()
  }
})

test('import posts a multipart body and reads the SSE file id', async () => {
  const { server, base, calls } = await startFake((call, response) => {
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    response.end('event: end\ndata: ["~u00000000-0000-0000-0000-000000000002"]\n\n')
  })
  const dir = await mkdtemp(join(tmpdir(), 'penpot-import-'))
  try {
    const path = join(dir, 'x.penpot')
    await writeFile(path, 'zipbytes')
    const client = createClient({ url: base, token: 'tok' })
    const result = await client.importBinfile({ path, name: 'Design', projectId: 'proj-1', fileId: 'file-3' })
    assert.equal(result.id, '00000000-0000-0000-0000-000000000002')
    assert.match(calls[0].type, /^multipart\/form-data; boundary=/)
    assert.match(calls[0].body, /name="project-id"/)
    assert.match(calls[0].body, /proj-1/)
    assert.match(calls[0].body, /name="file-id"/)
    assert.match(calls[0].body, /name="file"; filename="x\.penpot"/)
    assert.match(calls[0].body, /zipbytes/)
  } finally {
    server.close()
    await rm(dir, { recursive: true, force: true })
  }
})

test('a refused request is an ApiError with the status', async () => {
  const { server, base } = await startFake((call, response) => json(response, 401, { message: 'no' }))
  try {
    const client = createClient({ url: base, token: 'bad' })
    await assert.rejects(client.profile(), (error) => error.status === 401 && /401/.test(error.message))
  } finally {
    server.close()
  }
})

test('a missing token is a usage error before any request', async () => {
  await assert.rejects(main(['whoami', '--url', 'http://127.0.0.1:1', '--token', '']), /PENPOT_ACCESS_TOKEN is not set/)
  await assert.rejects(main(['whoami', '--url', '', '--token', 'x']), /PENPOT_API_URL is not set/)
})

test('the CLI file is executable so the installed symlink runs', async () => {
  const mode = (await stat(join(here, 'design/penpot.mjs'))).mode
  assert.notEqual(mode & 0o111, 0, 'design/penpot.mjs must be executable')
})

test('the CLI entry point exits 2 when the API refuses', async () => {
  const { server, base } = await startFake((call, response) => json(response, 403, { message: 'nope' }))
  try {
    await assert.rejects(
      exec('node', [join(here, 'design/penpot.mjs'), 'whoami', '--url', base, '--token', 'tok']),
      (error) => error.code === 2 && /403/.test(error.stderr),
    )
  } finally {
    server.close()
  }
})
