#!/usr/bin/env node
/** The setup tag and VERSION must agree, and VERSION must carry a DSH part. */
import { readFile } from 'node:fs/promises'

const ref = process.env.GITHUB_REF_NAME ?? ''
if (!ref.startsWith('v')) {
  console.log('not a release tag; version check skipped')
  process.exit(0)
}

const fail = (message) => { console.error(`version check: ${message}`); process.exit(1) }
const tag = ref.slice(1)
const match = /^(.+)-(\d+)\.(\d+)\.(\d+)$/.exec(tag)
if (match === null) fail(`tag ${ref} is not v<dsh>-<major>.<minor>.<patch>`)
const dsh = match[1]

const version = (await readFile(new URL('../VERSION', import.meta.url), 'utf8')).trim()
if (version !== tag) fail(`VERSION is ${version}, tag is ${tag}`)

// The runtime version is the DSH part of VERSION; install.sh derives it and
// installs @deepseek-ai/dsh@$DSH_VERSION. A separate pin would be a second
// source of truth, so its absence is part of the contract.
const env = await readFile(new URL('../.env.example', import.meta.url), 'utf8')
if (/^DSH_VERSION=/m.test(env)) fail('.env.example sets DSH_VERSION; it is derived from VERSION')

console.log(`version check ok: setup ${tag} (DSH ${dsh}; plugins are versioned independently)`)
