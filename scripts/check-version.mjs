#!/usr/bin/env node
/** The setup tag, VERSION, DSH_VERSION and the connector pin must agree. */
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

const env = (await readFile(new URL('../.env.example', import.meta.url), 'utf8'))
const dshLine = /^DSH_VERSION=(.+)$/m.exec(env)
if (dshLine === null || dshLine[1].trim() !== dsh) fail(`.env.example DSH_VERSION is not ${dsh}`)
const pinLine = /^DSH_TELEGRAM_PLUGIN=(.+)$/m.exec(env)
if (pinLine === null) fail('.env.example has no DSH_TELEGRAM_PLUGIN')
if (!pinLine[1].includes(`#v${tag}`)) fail(`connector pin is not #v${tag}`)

console.log(`version check ok: setup ${tag} (DSH ${dsh}, connector pinned to v${tag})`)
