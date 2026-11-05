/**
 * The plugin catalog and the entrypoint's version policy.
 *
 * These are contract tests: a setup release must not start deriving plugin
 * versions from `VERSION` again, and the catalog must stay parseable and
 * internally consistent. The installation paths themselves need root/systemd
 * and are covered by the native smoke workflow.
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const read = (name) => readFile(join(here, name), 'utf8')

test('the plugin catalog pins an npm spec, a GitHub fallback and a minimum', async () => {
  const catalog = JSON.parse(await read('plugins.json'))
  for (const name of ['dsh-telegram-connector', 'dsh-penpot-plugin']) {
    const entry = catalog.plugins?.[name]
    assert.ok(entry, `${name} is missing from plugins.json`)
    assert.match(entry.spec, /^(?:@[^/]+\/)?[^@]+@\d+\.\d+\.\d+/, `${name} spec`)
    assert.match(entry.fallback, /^github:[^#]+#v\d+\.\d+\.\d+/, `${name} fallback`)
    assert.match(entry.minimum, /^\d+\.\d+\.\d+/, `${name} minimum`)
    const version = entry.spec.split('@').pop()
    const tag = entry.fallback.split('#')[1].replace(/^v/, '')
    assert.equal(version, tag, `${name} npm spec and GitHub fallback disagree`)
    assert.ok(entry.minimum.localeCompare(version, undefined, { numeric: true }) <= 0,
      `${name} minimum ${entry.minimum} is above its pinned version ${version}`)
  }
})

test('the entrypoint does not derive a plugin spec from the setup version', async () => {
  const entry = await read('entrypoint.sh')
  assert.doesNotMatch(entry, /v\$\{?SETUP_VERSION\}?/, 'a plugin ref still uses SETUP_VERSION')
  assert.match(entry, /catalog_spec dsh-telegram-connector/)
  assert.match(entry, /catalog_spec dsh-penpot-plugin/)
  assert.match(entry, /PLUGIN_TARGET_REF/)
})

test('a boot enforces a minimum but never an exact pin', async () => {
  const entry = await read('entrypoint.sh')
  assert.match(entry, /version_gte/, 'no version comparison helper')
  assert.match(entry, /older than the required/)
  // The stamp is written for diagnostics; it must not be the install decision.
  assert.doesNotMatch(entry, /\[ "\$\(cat "\$stamp"\)" = "\$PLUGIN_REF" \]/,
    'the connector still reinstalls whenever the stamp differs')
})

test('the supervisor passes an explicit ref to reset-plugin', async () => {
  const supervisor = await read('supervisor.mjs')
  assert.match(supervisor, /DSH_PLUGIN_TARGET_REF/)
  assert.match(supervisor, /invalid plugin ref/)
})
