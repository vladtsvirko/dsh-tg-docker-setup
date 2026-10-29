import assert from 'node:assert/strict'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import http from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { createUpdater, parseTag, resolveTarget, UpdateError } from './updater.mjs'

const tags = [
  'v0.2.1-rc.2-0.0.1',
  'v0.2.1-rc.2-0.0.2',
  'v0.2.1-rc.2-0.1.0',
  'v0.2.1-rc.2-1.0.0',
  'v0.2.2-0.0.1',
  'v0.3.0-0.0.1',
]
const current = 'v0.2.1-rc.2-0.0.1'

test('parses aligned tags', () => {
  assert.deepEqual(parseTag('v0.2.1-rc.2-0.0.1'), {
    tag: 'v0.2.1-rc.2-0.0.1', dsh: '0.2.1-rc.2', major: 0, minor: 0, patch: 1,
  })
  assert.equal(parseTag('v0.2.1'), undefined)
  assert.equal(parseTag('nope'), undefined)
})

test('compatible stops at the same DSH line and product major', () => {
  assert.equal(resolveTarget(current, tags, { mode: 'compatible' }), 'v0.2.1-rc.2-0.1.0')
  assert.throws(
    () => resolveTarget(current, [current, 'v0.2.1-rc.2-1.0.0'], { mode: 'compatible' }),
    (error) => error instanceof UpdateError && error.status === 422,
  )
})

test('available picks the latest tag', () => {
  assert.equal(resolveTarget(current, tags, { mode: 'available' }), 'v0.3.0-0.0.1')
})

test('exact accepts newer tags and rejects older or unknown ones', () => {
  assert.equal(resolveTarget(current, tags, { mode: 'exact', version: '0.2.1-rc.2-0.0.2' }), 'v0.2.1-rc.2-0.0.2')
  assert.throws(() => resolveTarget(current, tags, { mode: 'exact', version: current }), UpdateError)
  assert.throws(() => resolveTarget(current, tags, { mode: 'exact', version: 'v9.9.9-0.0.1' }), UpdateError)
})

const start = async (app) => {
  const server = http.createServer((request, response) => void app.handler(request, response))
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  return { server, base: `http://127.0.0.1:${address.port}` }
}

test('endpoint validates token and returns a job', async () => {
  const app = createUpdater({ repo: '/unused', token: 'secret', tags: async () => tags, current: async () => current })
  const { server, base } = await start(app)
  try {
    assert.equal((await fetch(`${base}/health`)).status, 200)
    assert.equal((await fetch(`${base}/update`, { method: 'POST', body: '{}' })).status, 401)
    const bad = await fetch(`${base}/update`, {
      method: 'POST',
      headers: { authorization: 'Bearer secret' },
      body: JSON.stringify({ mode: 'nope' }),
    })
    assert.equal(bad.status, 400)
    const accepted = await fetch(`${base}/update`, {
      method: 'POST',
      headers: { authorization: 'Bearer secret' },
      body: JSON.stringify({ mode: 'compatible' }),
    })
    assert.equal(accepted.status, 202)
    const body = await accepted.json()
    assert.equal(body.target, 'v0.2.1-rc.2-0.1.0')
    const status = await fetch(`${base}/status`, { headers: { authorization: 'Bearer secret' } })
    assert.equal((await status.json()).job.state, 'accepted')
  } finally {
    server.close()
  }
})

test('apply runs update.sh and records the result', async () => {
  const repo = await mkdtemp(join(tmpdir(), 'updater-apply-'))
  try {
    await writeFile(join(repo, 'update.sh'), '#!/usr/bin/env bash\necho building dsh\nsleep 0.2\necho stopping dsh\necho starting dsh\nexit 0\n')
    const app = createUpdater({ repo, token: 'secret', apply: true, tags: async () => tags, current: async () => current })
    const { server, base } = await start(app)
    try {
      const accepted = await fetch(`${base}/update`, {
        method: 'POST', headers: { authorization: 'Bearer secret' }, body: '{"mode":"compatible"}',
      })
      assert.equal(accepted.status, 202)
      await new Promise((resolve) => setTimeout(resolve, 700))
      const status = await fetch(`${base}/status`, { headers: { authorization: 'Bearer secret' } })
      const job = (await status.json()).job
      assert.equal(job.state, 'done')
      assert.equal(job.exitCode, 0)
      assert.match(job.logTail, /building dsh/)
    } finally {
      server.close()
    }
  } finally {
    await rm(repo, { recursive: true, force: true })
  }
})

test('an empty token disables updates', async () => {
  const app = createUpdater({ repo: '/unused', token: '', tags: async () => tags, current: async () => current })
  const { server, base } = await start(app)
  try {
    assert.equal((await fetch(`${base}/update`, { method: 'POST', body: '{}' })).status, 503)
  } finally {
    server.close()
  }
})
