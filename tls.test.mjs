/**
 * Tests for scripts/design-tls.sh — the local CA and the Penpot HTTPS
 * certificate.
 *
 * The browser only exposes the clipboard API on a secure origin, so the design
 * stack publishes an HTTPS front signed by a local CA. The CA must survive a
 * re-issue (the operator trusts it once) and the server certificate must cover
 * the address the browser dials.
 *
 *   node --test tls.test.mjs
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const here = dirname(fileURLToPath(import.meta.url))
const script = join(here, 'scripts', 'design-tls.sh')
const exec = promisify(execFile)

const haveOpenssl = await exec('openssl', ['version']).then(() => true, () => false)
const run = (dir, bind) => exec('bash', [script, dir, bind])
const text = async (file) => exec('openssl', ['x509', '-in', file, '-noout', '-text']).then((r) => r.stdout)
const fingerprint = async (file) => exec('openssl', ['x509', '-in', file, '-noout', '-fingerprint', '-sha256']).then((r) => r.stdout.trim())

test('design-tls creates a CA and a server certificate for the bind address', { skip: !haveOpenssl }, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'design-tls-'))
  try {
    await run(dir, '192.168.2.98')
    const ca = join(dir, 'certs', 'ca.crt')
    const crt = join(dir, 'certs', 'server.crt')
    assert.match(await text(ca), /CA:TRUE/)
    const server = await text(crt)
    assert.match(server, /IP Address:192\.168\.2\.98/)
    assert.match(server, /DNS:localhost/)
    assert.match(server, /IP Address:127\.0\.0\.1/)
    await exec('openssl', ['verify', '-CAfile', ca, crt])
    assert.equal((await stat(join(dir, 'certs', 'ca.key'))).mode & 0o777, 0o600)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('design-tls keeps the CA and reuses the certificate for the same address', { skip: !haveOpenssl }, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'design-tls-'))
  try {
    await run(dir, '192.168.2.98')
    const caBefore = await fingerprint(join(dir, 'certs', 'ca.crt'))
    const crtBefore = await fingerprint(join(dir, 'certs', 'server.crt'))
    await run(dir, '192.168.2.98')
    assert.equal(await fingerprint(join(dir, 'certs', 'ca.crt')), caBefore)
    assert.equal(await fingerprint(join(dir, 'certs', 'server.crt')), crtBefore)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('design-tls re-issues the server certificate when the address changes', { skip: !haveOpenssl }, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'design-tls-'))
  try {
    await run(dir, '192.168.2.98')
    const caBefore = await fingerprint(join(dir, 'certs', 'ca.crt'))
    const crtBefore = await fingerprint(join(dir, 'certs', 'server.crt'))
    await run(dir, '192.168.2.99')
    assert.equal(await fingerprint(join(dir, 'certs', 'ca.crt')), caBefore)
    assert.notEqual(await fingerprint(join(dir, 'certs', 'server.crt')), crtBefore)
    assert.match(await text(join(dir, 'certs', 'server.crt')), /IP Address:192\.168\.2\.99/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})
