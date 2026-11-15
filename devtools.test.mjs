/**
 * Tests for the optional devtool catalog and planner.
 *
 * The installer itself downloads gigabytes; these tests prove the cheap
 * contract: pins are complete, `plan` is read-only and names the pins, a
 * missing tree is reported as missing, and setup.sh wires the flag through.
 *
 *   node --test devtools.test.mjs
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const here = dirname(fileURLToPath(import.meta.url))
const exec = promisify(execFile)
const script = join(here, 'scripts', 'devtools.sh')

async function run(args, { env = {} } = {}) {
  try {
    const { stdout, stderr } = await exec('bash', [script, ...args], {
      cwd: here,
      env: { ...process.env, NO_COLOR: '1', ...env },
    })
    return { code: 0, out: stdout + stderr }
  } catch (error) {
    return { code: error.code ?? 1, out: String(error.stdout ?? '') + String(error.stderr ?? '') }
  }
}

test('the catalog pins complete, versioned toolchains', async () => {
  const catalog = JSON.parse(await readFile(join(here, 'devtools.json'), 'utf8'))
  assert.equal(catalog.version, 1)
  for (const name of ['ios', 'android']) {
    const tool = catalog.tools[name]
    assert.ok(tool, `${name} is present`)
    assert.equal(typeof tool.label, 'string')
    assert.ok(tool.minFreeMB >= 1000, `${name} declares a disk floor`)
    assert.match(tool.note, /\S/)
  }
  assert.match(catalog.tools.ios.swift, /^\d+\.\d+\.\d+$/)
  assert.match(catalog.tools.ios.xtool, /^\d+\.\d+\.\d+$/)
  assert.match(catalog.tools.android.cmdlineTools, /^\d+$/)
  assert.ok(catalog.tools.android.packages.includes('platform-tools'))
  assert.ok(catalog.tools.android.packages.some((pkg) => pkg.startsWith('platforms;android-')))
  assert.ok(catalog.tools.android.packages.some((pkg) => pkg.startsWith('build-tools;')))
  assert.ok(catalog.tools.android.packages.some((pkg) => pkg.startsWith('ndk;')))
})

test('plan names both toolchains without touching the host', async () => {
  const { code, out } = await run(['plan', '--tools', 'all'])
  assert.equal(code, 0)
  assert.match(out, /iOS: Swift \d+\.\d+\.\d+ \+ xtool \d+\.\d+\.\d+/)
  assert.match(out, /Android: JDK, SDK android-\d+/)
  assert.match(out, /Xcode\.xip/)
})

test('plan accepts none and rejects an unknown toolchain', async () => {
  const none = await run(['plan', '--tools', 'none'])
  assert.equal(none.code, 0)
  assert.match(none.out, /none — DSH runs without them/)

  const bad = await run(['plan', '--tools', 'windows'])
  assert.notEqual(bad.code, 0)
  assert.match(bad.out, /unknown toolchain: windows/)
})

test('status reports a missing tree without creating it', async () => {
  const root = await mkdtemp(join(tmpdir(), 'devtools-empty-'))
  try {
    const { code, out } = await run(['status', '--tools', 'ios', '--root', root])
    assert.equal(code, 1)
    assert.match(out, /ios\s+missing/)
    const again = await readFile(join(here, 'devtools.json'), 'utf8')
    assert.match(again, /"xtool"/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('setup.sh exposes --devtools and the devtools command', async () => {
  const setup = await readFile(join(here, 'setup.sh'), 'utf8')
  assert.match(setup, /--devtools\) DEVTOOLS=/)
  assert.match(setup, /devtools\)\s+cmd_devtools/)
  assert.match(setup, /devtools_env_write "\$file" "\$DEVTOOLS"/)
  assert.match(setup, /DSH_DEVTOOLS/)
  assert.match(setup, /scripts\/devtools\.sh/)
  // Apple login is an explicit action, never part of install.
  assert.match(setup, /login\|apple-login\|logout\|auth-status\|sdk/)
  assert.match(setup, /run_as_service \/usr\/local\/bin\/xtool auth login/)
  assert.match(setup, /run_as_service env TMPDIR="\$sdk_tmp" "\$\{sdk_args\[@\]\}"/)
  assert.doesNotMatch(setup, /run_as_service xtool setup/)
})
