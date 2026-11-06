/**
 * Entrypoint plugin-policy tests.
 *
 * A fake `dsh` stands in for the real CLI so the boot decision can be asserted
 * without a network, a package manager or a running runtime:
 *
 *   - a missing plugin installs the catalog ref;
 *   - an installed version at or above `minimum` is left alone;
 *   - an installed version below `minimum` is upgraded;
 *   - an explicit update target wins for that one run;
 *   - a stale .env override below the minimum loses to the catalog;
 *   - reset-plugin reinstalls the installed spec, not the catalog pin.
 *
 *   node --test entrypoint.test.mjs
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { chmod, cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const here = dirname(fileURLToPath(import.meta.url))
const exec = promisify(execFile)

const CATALOG = {
  version: 2,
  plugins: {
    'dsh-telegram-connector': {
      spec: 'dsh-telegram-connector@0.13.0',
      fallback: 'github:vladtsvirko/dsh-telegram-connector#v0.13.0',
      minimum: '0.13.0',
    },
    'dsh-penpot-plugin': {
      spec: 'dsh-penpot-plugin@0.3.0',
      fallback: 'github:vladtsvirko/dsh-penpot-plugin#v0.3.0',
      minimum: '0.3.0',
    },
  },
}

/**
 * A dsh that records its arguments and materialises package installs in the
 * profile. It is intentionally not a real package manager: the entrypoint's
 * decision is what is under test, not pnpm.
 */
const fakeDsh = `#!/usr/bin/env node
const { mkdir, readFile, writeFile, rm } = require('node:fs/promises')
const { existsSync } = require('node:fs')
const { join } = require('node:path')

const args = process.argv.slice(2)
const home = process.env.DSH_HOME
const profile = join(home, 'profiles', 'web')

const readJson = async (file, fallback) => {
  try { return JSON.parse(await readFile(file, 'utf8')) } catch { return fallback }
}
const writeJson = async (file, value) => {
  await mkdir(join(file, '..'), { recursive: true })
  await writeFile(file, JSON.stringify(value, null, 2) + '\\n')
}

const main = async () => {
if (args[0] === '--version') {
  process.stdout.write('0.2.1-rc.5\\n')
  process.exit(0)
}
if (args[0] === '--profile' && args[2] === '--help') {
  await mkdir(profile, { recursive: true })
  if (!existsSync(join(profile, 'package.json'))) await writeJson(join(profile, 'package.json'), { dependencies: {} })
  if (!existsSync(join(profile, 'cordis.patch.yml'))) await writeFile(join(profile, 'cordis.patch.yml'), '[]\\n')
  process.exit(0)
}
if (args[0] !== 'plugin') process.exit(0)

const command = args[3]
const value = args[4]
const specOf = (spec) => {
  const npm = /^((?:@[^/]+\\/)?[^@]+)@([0-9][^@]*)$/.exec(String(spec))
  if (npm) return { name: npm[1], version: npm[2] }
  const base = String(spec).replace(/^github:/, '').replace(/#.*$/, '').replace(/\\.git$/, '').replace(/\\/$/, '')
  const name = base.split('/').filter(Boolean).pop()
  const match = /#v?([^#]+)$/.exec(String(spec))
  return { name, version: match ? match[1] : '0.0.0' }
}

if (command === 'add') {
  if (process.env.FAKE_FAIL === '1') process.exit(1)
  if (process.env.FAKE_FAIL_NPM === '1' && /^[^@]+@[0-9]/.test(String(value))) process.exit(1)
  const { name, version } = specOf(value)
  const pkg = await readJson(join(profile, 'package.json'), { dependencies: {} })
  // pnpm rejects a dependency value that repeats the package name, and one such
  // value fails the whole install, not just that package.
  for (const [dep, spec] of Object.entries(pkg.dependencies ?? {})) {
    if (typeof spec === 'string' && spec.startsWith(dep + '@') && /^[0-9]/.test(spec.slice(dep.length + 1))) {
      process.stderr.write('ERR_PNPM_SPEC_NOT_SUPPORTED_BY_ANY_RESOLVER ' + JSON.stringify(dep + '@' + spec) + '\\n')
      process.exit(1)
    }
  }
  const dir = join(profile, 'node_modules', name)
  await writeJson(join(dir, 'package.json'), {
    name,
    version,
    peerDependencies: { '@deepseek-ai/dsh-agent': '>=0.1.0-rc.6 <0.3.0-0' },
  })
  // pnpm saves an npm dependency as a range; the entrypoint pins it exactly.
  pkg.dependencies = { ...(pkg.dependencies ?? {}), [name]: /^[^@]+@[0-9]/.test(String(value)) ? '^' + version : value }
  await writeJson(join(profile, 'package.json'), pkg)
  process.exit(0)
}
if (command === 'remove') {
  const name = String(value)
  await rm(join(profile, 'node_modules', name), { recursive: true, force: true })
  const pkg = await readJson(join(profile, 'package.json'), { dependencies: {} })
  if (pkg.dependencies) delete pkg.dependencies[name]
  await writeJson(join(profile, 'package.json'), pkg)
  process.exit(0)
}
process.exit(0)
}
main().catch((error) => { console.error(error); process.exit(1) })
`

const fakeDshPath = async (root) => {
  const bin = join(root, 'bin')
  await mkdir(bin, { recursive: true })
  const file = join(bin, 'dsh')
  await writeFile(file, fakeDsh)
  await chmod(file, 0o755)
  return bin
}

/** A deployment-shaped checkout containing only what the entrypoint reads. */
async function deployment() {
  const root = await mkdtemp(join(tmpdir(), 'entrypoint-policy-'))
  const home = join(root, 'home')
  const workspace = join(root, 'workspace')
  const setup = join(root, 'setup')
  await mkdir(home, { recursive: true })
  await mkdir(workspace, { recursive: true })
  await mkdir(setup, { recursive: true })
  await cp(join(here, 'entrypoint.sh'), join(setup, 'entrypoint.sh'))
  await writeFile(join(setup, 'plugins.json'), JSON.stringify(CATALOG, null, 2) + '\n')
  await writeFile(join(setup, 'VERSION'), '0.2.1-rc.5-0.13.0\n')
  const bin = await fakeDshPath(root)
  return { root, home, workspace, setup, bin }
}

async function installFake(home, spec) {
  const npm = /^((?:@[^/]+\/)?[^@]+)@([0-9][^@]*)$/.exec(spec)
  const base = spec.replace(/^github:/, '').replace(/#.*$/, '').replace(/\.git$/, '').replace(/\/$/, '')
  const name = npm ? npm[1] : base.split('/').filter(Boolean).pop()
  const version = npm ? npm[2] : (/#v?([^#]+)$/.exec(spec)?.[1] ?? '0.0.0')
  const dir = join(home, 'profiles', 'web', 'node_modules', name)
  await mkdir(dir, { recursive: true })
  await writeFile(join(dir, 'package.json'), JSON.stringify({
    name,
    version,
    peerDependencies: { '@deepseek-ai/dsh-agent': '>=0.1.0-rc.6 <0.3.0-0' },
  }))
  const manifest = join(home, 'profiles', 'web', 'package.json')
  let pkg = { dependencies: {} }
  try { pkg = JSON.parse(await readFile(manifest, 'utf8')) } catch {}
  pkg.dependencies = { ...(pkg.dependencies ?? {}), [name]: npm ? version : spec }
  await mkdir(dirname(manifest), { recursive: true })
  await writeFile(manifest, JSON.stringify(pkg, null, 2))
  const patch = join(home, 'profiles', 'web', 'cordis.patch.yml')
  if (!existsSync(patch)) await writeFile(patch, '[]\n')
}

function envFor(parts, extra = {}) {
  return {
    ...process.env,
    HOME: parts.home,
    DSH_HOME: parts.home,
    DSH_WORKSPACE: parts.workspace,
    DSH_SETUP_VERSION: '0.2.1-rc.5-0.13.0',
    DSH_TELEGRAM_BOT_TOKEN: '123:test',
    ALLOWED_USER_IDS: '142283532',
    DSH_PROVIDER: 'test',
    DSH_MODEL: 'test-model',
    DSH_PROVIDER_API_KEY_ENV: 'TEST_KEY',
    TEST_KEY: 'x',
    PENPOT_ENABLED: '0',
    DSH_GIT_SECRETS: '/nonexistent',
    PATH: `${parts.bin}:${process.env.PATH}`,
    ...extra,
  }
}

async function run(parts, args, extra = {}) {
  return exec('bash', [join(parts.setup, 'entrypoint.sh'), ...args], {
    env: envFor(parts, extra),
    timeout: 30000,
  })
}

const installed = async (home, name = 'dsh-telegram-connector') => {
  try {
    return JSON.parse(await readFile(join(home, 'profiles', 'web', 'node_modules', name, 'package.json'), 'utf8')).version
  } catch {
    return undefined
  }
}

const recorded = async (home) => {
  try {
    return JSON.parse(await readFile(join(home, 'profiles', 'web', 'package.json'), 'utf8')).dependencies
  } catch {
    return {}
  }
}

test('a missing connector installs the catalog ref', async () => {
  const parts = await deployment()
  try {
    await run(parts, ['init'])
    assert.equal(await installed(parts.home), '0.13.0')
    assert.equal((await recorded(parts.home))['dsh-telegram-connector'], '0.13.0')
  } finally {
    await rm(parts.root, { recursive: true, force: true })
  }
})

test('a legacy name@version dependency is repaired before installing', async () => {
  const parts = await deployment()
  try {
    await run(parts, ['init'])
    // What 0.13.1 wrote: pnpm refuses the value, and the refusal fails every
    // install in the profile — here, the Penpot plugin.
    const manifest = join(parts.home, 'profiles', 'web', 'package.json')
    const pkg = JSON.parse(await readFile(manifest, 'utf8'))
    pkg.dependencies['dsh-telegram-connector'] = 'dsh-telegram-connector@0.13.0'
    pkg.dependencies['dsh-penpot-plugin'] = 'dsh-penpot-plugin@0.3.0'
    await writeFile(manifest, JSON.stringify(pkg, null, 2) + '\n')
    const { stderr } = await run(parts, ['init'], { PENPOT_ENABLED: '1' })
    assert.equal((await recorded(parts.home))['dsh-telegram-connector'], '0.13.0')
    assert.equal((await recorded(parts.home))['dsh-penpot-plugin'], '0.3.0')
    assert.equal(await installed(parts.home, 'dsh-penpot-plugin'), '0.3.0')
    assert.doesNotMatch(stderr, /SPEC_NOT_SUPPORTED/)
  } finally {
    await rm(parts.root, { recursive: true, force: true })
  }
})

test('a connector at or above the minimum is left alone', async () => {
  const parts = await deployment()
  try {
    await installFake(parts.home, 'dsh-telegram-connector@0.13.1')
    const { stderr } = await run(parts, ['init'])
    assert.equal(await installed(parts.home), '0.13.1')
    assert.equal((await recorded(parts.home))['dsh-telegram-connector'], '0.13.1')
    assert.doesNotMatch(stderr, /installing the Telegram adapter/)
  } finally {
    await rm(parts.root, { recursive: true, force: true })
  }
})

test('a connector below the minimum is upgraded to the catalog ref', async () => {
  const parts = await deployment()
  try {
    await installFake(parts.home, 'dsh-telegram-connector@0.12.0')
    await run(parts, ['init'])
    assert.equal(await installed(parts.home), '0.13.0')
  } finally {
    await rm(parts.root, { recursive: true, force: true })
  }
})

test('an explicit target ref wins for one run', async () => {
  const parts = await deployment()
  try {
    await installFake(parts.home, 'dsh-telegram-connector@0.13.1')
    await run(parts, ['init'], { DSH_PLUGIN_TARGET_REF: 'dsh-telegram-connector@0.14.0' })
    assert.equal(await installed(parts.home), '0.14.0')
    assert.equal((await recorded(parts.home))['dsh-telegram-connector'], '0.14.0')
  } finally {
    await rm(parts.root, { recursive: true, force: true })
  }
})

test('a stale .env override below the minimum loses to the catalog', async () => {
  const parts = await deployment()
  try {
    await installFake(parts.home, 'dsh-telegram-connector@0.12.0')
    const { stderr } = await run(parts, ['init'], {
      DSH_TELEGRAM_PLUGIN: 'dsh-telegram-connector@0.12.5',
    })
    assert.equal(await installed(parts.home), '0.13.0')
    assert.match(stderr, /below the required 0\.13\.0/)
  } finally {
    await rm(parts.root, { recursive: true, force: true })
  }
})

test('reset-plugin reinstalls the installed spec, not the catalog pin', async () => {
  const parts = await deployment()
  try {
    await installFake(parts.home, 'dsh-telegram-connector@0.14.0')
    await writeFile(join(parts.home, 'profiles', 'web', '.telegram-plugin-ref'), 'github:vladtsvirko/dsh-telegram-connector#v0.14.0\n')
    await run(parts, ['reset-plugin'])
    assert.equal(await installed(parts.home), '0.14.0')
    assert.equal((await recorded(parts.home))['dsh-telegram-connector'], '0.14.0')
  } finally {
    await rm(parts.root, { recursive: true, force: true })
  }
})

test('the GitHub fallback installs when the registry fails', async () => {
  const parts = await deployment()
  try {
    await run(parts, ['init'], { FAKE_FAIL_NPM: '1' })
    assert.equal(await installed(parts.home), '0.13.0')
    assert.equal((await recorded(parts.home))['dsh-telegram-connector'], CATALOG.plugins['dsh-telegram-connector'].fallback)
  } finally {
    await rm(parts.root, { recursive: true, force: true })
  }
})

test('a failed targeted update makes the entrypoint exit non-zero', async () => {
  const parts = await deployment()
  try {
    await installFake(parts.home, 'dsh-telegram-connector@0.13.1')
    // The fake rejects an explicitly broken repo by returning a non-zero add.
    const rejected = fakeDsh.replace("if (command === 'add') {", "if (command === 'add' && String(value).includes('broken')) process.exit(1)\\nif (command === 'add') {")
    await writeFile(join(parts.bin, 'dsh'), rejected)
    await chmod(join(parts.bin, 'dsh'), 0o755)
    await assert.rejects(
      run(parts, ['init'], { DSH_PLUGIN_TARGET_REF: 'github:broken/connector#v0.14.0' }),
      (error) => error.code !== 0,
    )
  } finally {
    await rm(parts.root, { recursive: true, force: true })
  }
})
