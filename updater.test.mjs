import assert from 'node:assert/strict'
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import http from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { test } from 'node:test'
import { createUpdater, crossesCompat, firewallPorts, networkOf, parseTag, resolveTarget, UpdateError } from './updater.mjs'

const exec = promisify(execFile)

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
    const target = await fetch(`${base}/target`, {
      method: 'POST',
      headers: { authorization: 'Bearer secret' },
      body: JSON.stringify({ mode: 'compatible' }),
    })
    assert.equal(target.status, 200)
    assert.equal((await target.json()).target, 'v0.2.1-rc.2-0.1.0')
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
    const app = createUpdater({ repo, token: 'secret', apply: true, tags: async () => tags, current: async () => current, exit: () => {} })
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

test('components: catalog, validation and a fixed apply command', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'updater-components-'))
  const logFile = join(dir, 'component.log')
  try {
    await writeFile(join(dir, 'components.json'), JSON.stringify({
      version: 1,
      components: {
        design: {
          label: 'Design (Penpot)',
          description: 'Penpot',
          compose: 'design/compose.yaml',
          projectDir: 'design',
          envFile: 'design/.env',
          template: 'design/.env.example',
          flag: 'DSH_DESIGN_ENABLED',
          config: { port: { env: 'DSH_DESIGN_PORT', default: 8090, min: 1024, max: 65535 } },
          health: { url: 'http://{bind}:{port}/', codes: [200] },
        },
      },
    }))
    await writeFile(join(dir, '.env'), 'DSH_DESIGN_ENABLED=0\nDSH_DESIGN_PORT=8090\n')
    await writeFile(join(dir, 'update.sh'), '#!/bin/sh\necho "$*" > "$PWD/component.log"\nexit 0\n', { mode: 0o755 })

    const app = createUpdater({ repo: dir, token: 'secret', apply: true, tags: async () => tags, current: async () => current })
    const { server, base } = await start(app)
    try {
      assert.equal((await fetch(`${base}/components`)).status, 401)
      const catalog = await fetch(`${base}/components`, { headers: { authorization: 'Bearer secret' } })
      assert.equal(catalog.status, 200)
      const { components } = await catalog.json()
      assert.equal(components.length, 1)
      assert.equal(components[0].name, 'design')
      assert.equal(components[0].enabled, false)
      assert.equal(components[0].port, 8090)

      const post = (body) => fetch(`${base}/components`, {
        method: 'POST',
        headers: { authorization: 'Bearer secret' },
        body: JSON.stringify(body),
      })

      assert.equal((await post({ name: 'nope', action: 'enable' })).status, 422)
      assert.equal((await post({ name: 'design', action: 'explode' })).status, 400)
      assert.equal((await post({ name: 'design', action: 'enable', port: 80 })).status, 400)

      const accepted = await post({ name: 'design', action: 'enable', port: 8091 })
      assert.equal(accepted.status, 202)
      const body = await accepted.json()
      assert.equal(body.component, 'design')
      assert.equal(body.action, 'enable')

      let ran = ''
      for (let i = 0; i < 50 && ran.length === 0; i += 1) {
        await new Promise((resolve) => setTimeout(resolve, 100))
        ran = await readFile(logFile, 'utf8').catch(() => '')
      }
      assert.match(ran, /^--component design enable --port 8091/m)

      const status = await fetch(`${base}/status`, { headers: { authorization: 'Bearer secret' } })
      const job = (await status.json()).job
      assert.equal(job.state, 'done')
      assert.equal(job.component, 'design')
    } finally {
      server.close()
    }
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('components: the endpoint runs the real update.sh and wires the runtime', async (t) => {
  const outer = await mkdtemp(join(tmpdir(), 'updater-component-e2e-'))
  const repo = join(outer, 'repo')
  const bins = join(outer, 'bin')
  await mkdir(repo, { recursive: true })
  const probe = join(outer, '.probe')
  await writeFile(probe, '#!/bin/sh\nexit 0\n', { mode: 0o755 })
  try {
    await exec(probe)
  } catch {
    t.skip('temp directory is noexec (run with TMPDIR on an exec-capable filesystem)')
    await rm(outer, { recursive: true, force: true })
    return
  }

  const originalPath = process.env.PATH
  try {
    await copyFile(new URL('./update.sh', import.meta.url), join(repo, 'update.sh'))
    await copyFile(new URL('./components.json', import.meta.url), join(repo, 'components.json'))
    await mkdir(join(repo, 'design'), { recursive: true })
    await copyFile(new URL('./design/.env.example', import.meta.url), join(repo, 'design', '.env.example'))
    await writeFile(join(repo, 'VERSION'), '0.2.1-rc.2-0.4.0\n')
    await writeFile(join(repo, '.env'), 'DSH_BIND_IP=127.0.0.1\n')

    await mkdir(bins, { recursive: true })
    await writeFile(join(bins, 'docker'), '#!/bin/sh\nexit 0\n', { mode: 0o755 })
    await writeFile(join(bins, 'curl'), '#!/bin/sh\nprintf 200\n', { mode: 0o755 })
    await writeFile(join(bins, 'systemctl'), '#!/bin/sh\nexit 0\n', { mode: 0o755 })
    process.env.PATH = `${bins}:${originalPath}`

    const app = createUpdater({ repo, token: 'secret', apply: true, tags: async () => tags, current: async () => current })
    const { server, base } = await start(app)
    try {
      const accepted = await fetch(`${base}/components`, {
        method: 'POST',
        headers: { authorization: 'Bearer secret' },
        body: JSON.stringify({ name: 'design', action: 'enable', port: 8092 }),
      })
      assert.equal(accepted.status, 202)

      let job
      for (let i = 0; i < 100; i += 1) {
        await new Promise((resolve) => setTimeout(resolve, 100))
        const status = await fetch(`${base}/status`, { headers: { authorization: 'Bearer secret' } })
        job = (await status.json()).job
        if (job?.state === 'done' || job?.state === 'failed') break
      }
      assert.equal(job?.state, 'done', `job state: ${job?.state}\n${job?.logTail ?? ''}`)

      const mainEnv = await readFile(join(repo, '.env'), 'utf8')
      const designEnv = await readFile(join(repo, 'design', '.env'), 'utf8')
      assert.match(mainEnv, /DSH_DESIGN_ENABLED=1/)
      assert.match(mainEnv, /PENPOT_API_URL=http:\/\/127\.0\.0\.1:8092/)
      assert.match(designEnv, /DSH_DESIGN_PORT=8092/)
    } finally {
      server.close()
    }
  } finally {
    process.env.PATH = originalPath
    await rm(outer, { recursive: true, force: true })
  }
})

test('a job that runs past its deadline is killed and reported as failed', async () => {
  const repo = await mkdtemp(join(tmpdir(), 'updater-timeout-'))
  try {
    // Ignores SIGTERM's default only in the sense that it never finishes on its
    // own: the updater must kill it, not wait for it.
    await writeFile(join(repo, 'update.sh'), '#!/usr/bin/env bash\necho building dsh\nsleep 30\n')
    const app = createUpdater({
      repo, token: 'secret', apply: true,
      tags: async () => tags, current: async () => current,
      exit: () => {}, jobTimeoutMs: 700,
    })
    const { server, base } = await start(app)
    try {
      const accepted = await fetch(`${base}/update`, {
        method: 'POST', headers: { authorization: 'Bearer secret' }, body: '{"mode":"compatible"}',
      })
      assert.equal(accepted.status, 202)
      let job
      const deadline = Date.now() + 10000
      while (Date.now() < deadline) {
        const status = await fetch(`${base}/status`, { headers: { authorization: 'Bearer secret' } })
        job = (await status.json()).job
        if (['failed', 'done', 'rolled-back', 'cancelled'].includes(job.state)) break
        await new Promise((resolve) => setTimeout(resolve, 100))
      }
      assert.equal(job.state, 'failed')
      assert.match(String(job.error), /timed out/)
      const status = await fetch(`${base}/status`, { headers: { authorization: 'Bearer secret' } })
      const payload = await status.json()
      assert.equal(payload.cancellable, false)
      assert.equal(payload.timeoutSeconds, 1)
    } finally {
      server.close()
    }
  } finally {
    await rm(repo, { recursive: true, force: true })
  }
})

test('cancel stops a running job and says so', async () => {
  const repo = await mkdtemp(join(tmpdir(), 'updater-cancel-'))
  try {
    await writeFile(join(repo, 'update.sh'), '#!/usr/bin/env bash\necho building dsh\nsleep 30\n')
    const app = createUpdater({
      repo, token: 'secret', apply: true,
      tags: async () => tags, current: async () => current,
      exit: () => {}, jobTimeoutMs: 60000,
    })
    const { server, base } = await start(app)
    try {
      const headers = { authorization: 'Bearer secret' }
      assert.equal((await fetch(`${base}/update`, { method: 'POST', headers, body: '{"mode":"compatible"}' })).status, 202)
      let running = false
      const deadline = Date.now() + 5000
      while (Date.now() < deadline) {
        const status = await fetch(`${base}/status`, { headers })
        running = (await status.json()).cancellable === true
        if (running) break
        await new Promise((resolve) => setTimeout(resolve, 100))
      }
      assert.equal(running, true, 'the job must be running before it can be cancelled')
      const cancelled = await fetch(`${base}/cancel`, { method: 'POST', headers, body: '{}' })
      assert.equal(cancelled.status, 202)
      let job
      const end = Date.now() + 10000
      while (Date.now() < end) {
        const status = await fetch(`${base}/status`, { headers })
        job = (await status.json()).job
        if (['cancelled', 'failed', 'done', 'rolled-back'].includes(job.state)) break
        await new Promise((resolve) => setTimeout(resolve, 100))
      }
      assert.equal(job.state, 'cancelled')
      // Nothing left to cancel.
      assert.equal((await fetch(`${base}/cancel`, { method: 'POST', headers, body: '{}' })).status, 409)
    } finally {
      server.close()
    }
  } finally {
    await rm(repo, { recursive: true, force: true })
  }
})

test('a cross-line target needs the explicit flag', async () => {
  // "available" is a mode, not a permission: without this, whoever holds the
  // token could jump a DSH line or a product major without the flag that both
  // /system and update.sh require.
  assert.equal(crossesCompat('v0.2.1-rc.2-0.4.0', 'v0.2.1-rc.2-0.5.0'), false)
  assert.equal(crossesCompat('v0.2.1-rc.2-0.5.0', 'v0.3.0-0.0.1'), true)
  assert.equal(crossesCompat('v0.2.1-rc.2-0.5.0', 'v0.2.1-rc.2-1.0.0'), true)

  const app = createUpdater({ repo: '/unused', token: 'secret', tags: async () => tags, current: async () => current })
  const { server, base } = await start(app)
  try {
    const refused = await fetch(`${base}/update`, {
      method: 'POST', headers: { authorization: 'Bearer secret' }, body: '{"mode":"available"}',
    })
    assert.equal(refused.status, 422)
    assert.match((await refused.json()).error, /crosses a DSH line or a product major/)

    const allowed = await fetch(`${base}/update`, {
      method: 'POST', headers: { authorization: 'Bearer secret' }, body: '{"mode":"available","incompatible":true}',
    })
    assert.equal(allowed.status, 202)
  } finally {
    server.close()
  }
})

// --- firewall advice ------------------------------------------------------
// The updater answers for a native host only: a published Docker port is DNATed
// before ufw's INPUT chain sees it, so a rule there changes nothing.

test('networkOf prints the network, not the host address', () => {
  assert.equal(networkOf('192.168.2.98/24'), '192.168.2.0/24')
  assert.equal(networkOf('172.22.0.2/16'), '172.22.0.0/16')
  assert.equal(networkOf('10.0.0.1/32'), '10.0.0.1/32')
  assert.equal(networkOf('not-an-ip'), 'not-an-ip')
})

const active = ['Status: active', 'To                         Action      From',
  '--                         ------      ----', '22/tcp                     ALLOW       192.168.2.0/24'].join('\n')

test('a blocked native port is reported with the derived network', () => {
  const report = firewallPorts({ ports: [{ port: 4310, bind: '192.168.2.98/24' }], status: active })
  assert.equal(report.applicable, true)
  assert.deepEqual(report.ports, [{ port: 4310, bind: '192.168.2.98/24', network: '192.168.2.0/24', allowed: false }])
})

test('an allowed port is reported as allowed, and loopback binds are skipped', () => {
  const allowed = firewallPorts({
    mode: 'native',
    ports: [{ port: 4310, bind: '192.168.2.98/24' }],
    status: `${active}\n4310/tcp                   ALLOW       192.168.2.0/24`,
  })
  assert.equal(allowed.ports[0].allowed, true)
  const loopback = firewallPorts({ ports: [{ port: 4310, bind: '127.0.0.1' }], status: active })
  assert.equal(loopback.applicable, false)
})

test('inactive ufw and a missing status are not applicable', () => {
  assert.match(firewallPorts({ ports: [{ port: 4310, bind: '192.168.2.98' }], status: 'Status: inactive' }).reason, /not active/)
  assert.match(firewallPorts({ ports: [{ port: 4310, bind: '192.168.2.98' }] }).reason, /not installed/)
})
