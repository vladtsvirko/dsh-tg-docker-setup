#!/usr/bin/env node
/** The setup tag, VERSION, image tags and hardcoded DSH/setup versions must agree. */
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
if (/^DSH_VERSION=/m.test(env)) fail('.env.example still sets DSH_VERSION; it is hardcoded per release')

const compose = await readFile(new URL('../compose.yaml', import.meta.url), 'utf8')
if (!compose.includes(`image: dsh-backend:${tag}`)) fail(`compose.yaml has no dsh-backend:${tag}`)
if (!compose.includes(`image: dsh-updater:${tag}`)) fail(`compose.yaml has no dsh-updater:${tag}`)
const dockerfile = await readFile(new URL('../Dockerfile', import.meta.url), 'utf8')
if (!dockerfile.includes(`ARG DSH_VERSION=${dsh}`)) fail(`Dockerfile DSH_VERSION is not ${dsh}`)
if (!dockerfile.includes(`ARG DSH_SETUP_VERSION=${tag}`)) fail(`Dockerfile DSH_SETUP_VERSION is not ${tag}`)

console.log(`version check ok: setup ${tag} (DSH ${dsh}, connector derived from setup version)`)
